#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
if [ -f "$ROOT_DIR/.env" ]; then
  set -o allexport; source "$ROOT_DIR/.env"; set +o allexport
fi

AWS_REGION="${AWS_REGION:-us-east-1}"
BUCKET_NAME="${BUCKET_NAME:-}"
TOPIC_NAME="${TOPIC_NAME:-image-keys-topic}"
QUEUE_NAME="${QUEUE_NAME:-image-keys-queue}"
LAMBDA_NAME="${LAMBDA_NAME:-image-key-publisher}"
ECR_REPO="${ECR_REPO:-image-consumer}"
EKS_CLUSTER="${EKS_CLUSTER:-image-pipeline}"
EKS_IAM_USER_NAME="${EKS_IAM_USER_NAME:-image-pipeline-consumer}"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_PARTITION="aws"

# Delete k8s + EKS cluster
kubectl delete ns image-pipeline --ignore-not-found
eksctl delete cluster --name "$EKS_CLUSTER" --region "$AWS_REGION" || true

# Delete Lambda + role inline policy
aws lambda delete-function --function-name "$LAMBDA_NAME" --region "$AWS_REGION" || true
ROLE_NAME="${PROJECT:-image-pipeline}-lambda-role"
aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name lambda-inline >/dev/null 2>&1 || true
aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn arn:$AWS_PARTITION:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole >/dev/null 2>&1 || true
aws iam delete-role --role-name "$ROLE_NAME" >/dev/null 2>&1 || true

# Delete S3 objects + bucket (careful!)
if [ -n "${BUCKET_NAME}" ]; then
  aws s3 rm "s3://${BUCKET_NAME}" --recursive --region "$AWS_REGION" || true
  aws s3api delete-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION" || true
fi

# Delete SQS subscription policy and queue
QUEUE_URL=$(aws sqs get-queue-url --queue-name "$QUEUE_NAME" --region "$AWS_REGION" --query QueueUrl --output text 2>/dev/null || echo "")
if [ -n "$QUEUE_URL" ]; then
  aws sqs delete-queue --queue-url "$QUEUE_URL" --region "$AWS_REGION" || true
fi

# Delete SNS topic
TOPIC_ARN=$(aws sns list-topics --region "$AWS_REGION" --query "Topics[?contains(TopicArn, \`${TOPIC_NAME}\`)].TopicArn | [0]" --output text 2>/dev/null || echo "")
if [ "$TOPIC_ARN" != "None" ] && [ -n "$TOPIC_ARN" ]; then
  aws sns delete-topic --topic-arn "$TOPIC_ARN" --region "$AWS_REGION" || true
fi

# Delete ECR repo (and images)
aws ecr delete-repository --repository-name "$ECR_REPO" --region "$AWS_REGION" --force >/dev/null 2>&1 || true

# Delete IAM user & policy
POL_ARN=$(aws iam list-policies --query 'Policies[?PolicyName==`image-pipeline-consumer`].Arn' --output text 2>/dev/null || echo "")
if [ -n "$POL_ARN" ]; then
  aws iam detach-user-policy --user-name "$EKS_IAM_USER_NAME" --policy-arn "$POL_ARN" >/dev/null 2>&1 || true
fi
# delete all access keys
for AKID in $(aws iam list-access-keys --user-name "$EKS_IAM_USER_NAME" --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null); do
  aws iam delete-access-key --user-name "$EKS_IAM_USER_NAME" --access-key-id "$AKID" >/dev/null 2>&1 || true
done
aws iam delete-user --user-name "$EKS_IAM_USER_NAME" >/dev/null 2>&1 || true

echo "Teardown complete."
