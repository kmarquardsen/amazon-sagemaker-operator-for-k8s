#!/bin/bash

source codebuild/scripts/deployment_constants.sh

set -e

# Define alpha artifact locations
printf -v ALPHA_BUCKET_PREFIX $ALPHA_BINARY_PREFIX_FMT $ALPHA_TARBALL_BUCKET $CODEBUILD_RESOLVED_SOURCE_VERSION

printf -v ALPHA_LINUX_BINARY_PATH $ALPHA_LINUX_BINARY_PATH_FMT $ALPHA_BUCKET_PREFIX
printf -v ALPHA_DARWIN_BINARY_PATH $ALPHA_DARWIN_BINARY_PATH_FMT $ALPHA_BUCKET_PREFIX

# This function deploys a region-specific operator to an ECR prod repo from the existing
# image in the alpha repository. The function also copies across the smlogs binaries
# from the alpha tarball bucket into the production buckets.
# Parameter:
#    $1: The account ID for the ECR repo.
#    $2: The region of the ECR repo.
#    $3: The name of the ECR repository.
function deploy_from_alpha()
{
  local account_id="$1"
  local account_region="$2"
  local image_repository="$3"

  # Get the images from the alpha ECR repository
  local dest_ecr_image=${account_id}.dkr.ecr.${account_region}.amazonaws.com/${image_repository}
  local alpha_ecr_image=$ALPHA_ACCOUNT_ID.dkr.ecr.$ALPHA_REPOSITORY_REGION.amazonaws.com/${image_repository}

  # Login to the alpha repository
  $(aws ecr get-login --no-include-email --region $ALPHA_REPOSITORY_REGION --registry-ids $ALPHA_ACCOUNT_ID)
  docker pull $alpha_ecr_image:$CODEBUILD_RESOLVED_SOURCE_VERSION

  # Login to the prod repository
  $(aws ecr get-login --no-include-email --region ${account_region} --registry-ids ${account_id})

  # Clone the controller image to the repo
  docker tag $alpha_ecr_image:$CODEBUILD_RESOLVED_SOURCE_VERSION ${dest_ecr_image}:$CODEBUILD_RESOLVED_SOURCE_VERSION
  # TODO: Remove at the time of the next major version release
  # This moves the `latest` tag along with master branch, which will cause backwards incompatibility for any major
  # version updates.
  docker tag $alpha_ecr_image:$CODEBUILD_RESOLVED_SOURCE_VERSION ${dest_ecr_image}:latest

  # Push to the prod region
  docker push ${dest_ecr_image}:$CODEBUILD_RESOLVED_SOURCE_VERSION

  printf -v bucket_name $RELEASE_BUCKET_NAME_FMT $RELEASE_TARBALL_BUCKET_PREFIX $account_region
  printf -v binary_prefix $RELEASE_BINARY_PREFIX_FMT $bucket_name

  aws s3 cp "$ALPHA_LINUX_BINARY_PATH" "$(printf $RELEASE_LINUX_BINARY_PATH_FMT $binary_prefix $CODEBUILD_RESOLVED_SOURCE_VERSION)" $PUBLIC_CP_ARGS
  aws s3 cp "$ALPHA_DARWIN_BINARY_PATH" "$(printf $RELEASE_DARWIN_BINARY_PATH_FMT $binary_prefix $CODEBUILD_RESOLVED_SOURCE_VERSION)" $PUBLIC_CP_ARGS
}

# This function builds, packages and deploys a region-specific operator to an ECR repo and output bucket.
# Parameter:
#    $1: The account ID for the ECR repo.
#    $2: The region of the ECR repo.
#    $3: The name of the ECR repository.
#    $4: The stage in the pipeline for the output account. (prod/beta/dev)
#    $5: (Optional) A suffix for the operator install bundle tarball.
# e.g. package_operator 123456790 us-east-1 amazon-sagemaker-k8s-operator prod
function package_operator()
{
  local account_id="$1"
  local account_region="$2"
  local image_repository="$3"
  local stage="$4"
  local tarball_suffix="${5:-}"

  # Only build images that match the release pipeline stage
  if [ "$stage" != "$PIPELINE_STAGE" ] && [ "$stage" != "all" ]; then
    return 0
  fi

  # Only push to ECR repos if this is run on the prod pipeline
  if [ "$stage" == "prod" ] && [ "$PIPELINE_STAGE" == "prod" ]; then
    deploy_from_alpha "$account_id" "$account_region" "$image_repository"
  fi

  # Build, push and update the CRD with controller image and current git SHA, create the tarball and extract it to pack
  local ecr_image=${account_id}.dkr.ecr.${account_region}.amazonaws.com/${image_repository}
  make modify-base-kustomize-us IMG=${ecr_image}:$CODEBUILD_RESOLVED_SOURCE_VERSION
  make build-release-tarball
  pushd bin
    tar -xf sagemaker-k8s-operator-install-scripts.tar.gz
  popd

  # Create the smlog binary
  pushd smlogs-kubectl-plugin
    make build-release
  popd

  # Create a temporary dir and put all the necessary artifacts
  rm -rf /tmp/sagemaker-k8s-operator
  mkdir -p /tmp/sagemaker-k8s-operator
  mkdir -p /tmp/sagemaker-k8s-operator/smlogs-plugin/darwin.amd64
  mkdir -p /tmp/sagemaker-k8s-operator/smlogs-plugin/linux.amd64

  cp -r bin/sagemaker-k8s-operator-install-scripts /tmp/sagemaker-k8s-operator
  cp smlogs-kubectl-plugin/bin/kubectl-smlogs.linux.amd64 /tmp/sagemaker-k8s-operator/smlogs-plugin/linux.amd64/kubectl-smlogs
  cp smlogs-kubectl-plugin/bin/kubectl-smlogs.darwin.amd64 /tmp/sagemaker-k8s-operator/smlogs-plugin/darwin.amd64/kubectl-smlogs

  if [ "$SHOULD_PUSH_SMLOGS_ALPHA" == "true" ]; then
    # Create temp dirs per binary and put smlogs into it
    mkdir -p /tmp/kubectl-smlogs.linux.amd64
    mkdir -p /tmp/kubectl-smlogs.darwin.amd64

    cp smlogs-kubectl-plugin/bin/kubectl-smlogs.linux.amd64 /tmp/kubectl-smlogs.linux.amd64/kubectl-smlogs
    cp smlogs-kubectl-plugin/bin/kubectl-smlogs.darwin.amd64 /tmp/kubectl-smlogs.darwin.amd64/kubectl-smlogs

    pushd /tmp
      tar cvzf kubectl-smlogs-plugin.linux.amd64.tar.gz kubectl-smlogs.linux.amd64
      tar cvzf kubectl-smlogs-plugin.darwin.amd64.tar.gz kubectl-smlogs.darwin.amd64

      aws s3 cp kubectl-smlogs-plugin.linux.amd64.tar.gz "$ALPHA_LINUX_BINARY_PATH"
      aws s3 cp kubectl-smlogs-plugin.darwin.amd64.tar.gz "$ALPHA_DARWIN_BINARY_PATH"
    popd
  fi

  # Create a tar ball which has CRDs, smlog and sm spec generator binaries
  pushd /tmp
    tar cvzf sagemaker-k8s-operator.tar.gz sagemaker-k8s-operator

    # Upload the final tar ball to s3 with standard name and git SHA
    aws s3 cp sagemaker-k8s-operator.tar.gz "$ALPHA_BUCKET_PREFIX/sagemaker-k8s-operator-${account_region}${tarball_suffix}.tar.gz"
  popd
}
