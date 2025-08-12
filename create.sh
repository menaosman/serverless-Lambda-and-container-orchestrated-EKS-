#!/usr/bin/env bash
set -euo pipefail

# Load .env if present
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
if [ -f "$ROOT_DIR/.env" ]; then
  set -o allexport; source "$ROOT_DIR/.env"; set +o allexport
fi

AWS_REGION="${AWS_REGION:-us-east-1}"
PROJECT="${PROJECT:-image-pipeline}"
BUCKET_NAME="${BUCKET_NAME:-my-raw-images-$(date +%s)}"
TOPIC_NAME="${TOPIC_NAME:-image-keys-topic}"
QUEUE_NAME="${QUEUE_NAME:-image-keys-queue}"
LAMBDA_NAME="${LAMBDA_NAME:-image-key-publisher}"
ECR_REPO="${ECR_REPO:-image-consumer}"
EKS_CLUSTER="${EKS_CLUSTER:-image-pipeline}"
EKS_NODE_TYPE="${EKS_NODE_TYPE:-t3.small}"
EKS_NODE_COUNT="${EKS_NODE_COUNT:-1}"
ALARM_EMAIL="${ALARM_EMAIL:menaosman839@gmail.com}"
EKS_IAM_USER_NAME="${EKS_IAM_USER_NAME:-image-pipeline-consumer}"

echo "Region: $AWS_REGION"
echo "Bucket: $BUCKET_NAME"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_PARTITION="aws"

# Create S3 bucket
if [[ "$AWS_REGION" == "us-east-1" ]]; then
  aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION" || true
else
  aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION" --create-bucket-configuration LocationConstraint="$AWS_REGION" || true
fi

# Create SNS topic
TOPIC_ARN=$(aws sns create-topic --name "$TOPIC_NAME" --region "$AWS_REGION" --query TopicArn --output text)
echo "SNS Topic: $TOPIC_ARN"

# Email subscription (confirm email)
aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol email --notification-endpoint "$ALARM_EMAIL" --region "$AWS_REGION" >/dev/null || true

# Create SQS queue
QUEUE_URL=$(aws sqs create-queue --queue-name "$QUEUE_NAME" --attributes '{"ReceiveMessageWaitTimeSeconds":"20"}' --region "$AWS_REGION" --query QueueUrl --output text)
QUEUE_ARN=$(aws sqs get-queue-attributes --queue-url "$QUEUE_URL" --attribute-names QueueArn --region "$AWS_REGION" --query 'Attributes.QueueArn' --output text)
echo "SQS: $QUEUE_URL"

# Subscribe SQS to SNS with RawDelivery
aws sns subscribe   --topic-arn "$TOPIC_ARN"   --protocol sqs   --notification-endpoint "$QUEUE_ARN"   --attributes RawMessageDelivery=true   --region "$AWS_REGION" >/dev/null || true

# Allow SNS to publish to SQS
aws sqs set-queue-attributes --queue-url "$QUEUE_URL" --attributes "Policy=$(cat <<POL
{
  "Version": "2012-10-17",
  "Id": "SQSPolicy",
  "Statement": [{
    "Sid": "Allow-SNS-SendMessage",
    "Effect": "Allow",
    "Principal": {"Service": "sns.amazonaws.com"},
    "Action": "sqs:SendMessage",
    "Resource": "$QUEUE_ARN",
    "Condition": {"ArnEquals": {"aws:SourceArn": "$TOPIC_ARN"}}
  }]
}
POL
)" --region "$AWS_REGION"

# ECR repo
aws ecr describe-repositories --repository-names "$ECR_REPO" --region "$AWS_REGION" >/dev/null 2>&1 ||   aws ecr create-repository --repository-name "$ECR_REPO" --image-scanning-configuration scanOnPush=true --region "$AWS_REGION" >/dev/null

ECR_URI="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.${AWS_PARTITION}.com/${ECR_REPO}:v1"
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.${AWS_PARTITION}.com"

# Build & push image
pushd "$ROOT_DIR/eks-app" >/dev/null
docker build -t "$ECR_URI" .
docker push "$ECR_URI"
popd >/dev/null

# Package Lambda
pushd "$ROOT_DIR/lambda" >/dev/null
npm ci --omit=dev
zip -q -r lambda.zip index.js node_modules package.json
popd >/dev/null

# IAM role for Lambda
LAMBDA_ROLE_NAME="${PROJECT}-lambda-role"
ASSUME_ROLE_DOC='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam create-role --role-name "$LAMBDA_ROLE_NAME" --assume-role-policy-document "$ASSUME_ROLE_DOC" >/dev/null 2>&1 || true
aws iam attach-role-policy --role-name "$LAMBDA_ROLE_NAME" --policy-arn arn:$AWS_PARTITION:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole >/dev/null 2>&1 || true
# Publish to SNS + read S3 object meta
aws iam put-role-policy --role-name "$LAMBDA_ROLE_NAME" --policy-name lambda-inline --policy-document "file://$SCRIPT_DIR/iam-policies/lambda-publish-policy.json"

# Create/Update Lambda
ROLE_ARN=$(aws iam get-role --role-name "$LAMBDA_ROLE_NAME" --query Role.Arn --output text)
LAMBDA_EXISTS=$(aws lambda get-function --function-name "$LAMBDA_NAME" --region "$AWS_REGION" 2>/dev/null || true)
if [ -z "$LAMBDA_EXISTS" ]; then
  aws lambda create-function     --function-name "$LAMBDA_NAME"     --runtime nodejs18.x     --role "$ROLE_ARN"     --handler index.handler     --zip-file fileb://"$ROOT_DIR/lambda/lambda.zip"     --environment "Variables={AWS_REGION=$AWS_REGION,TOPIC_ARN=$TOPIC_ARN}"     --timeout 15     --memory-size 128     --region "$AWS_REGION" >/dev/null
else
  aws lambda update-function-code --function-name "$LAMBDA_NAME" --zip-file fileb://"$ROOT_DIR/lambda/lambda.zip" --region "$AWS_REGION" >/dev/null
  aws lambda update-function-configuration --function-name "$LAMBDA_NAME" --environment "Variables={AWS_REGION=$AWS_REGION,TOPIC_ARN=$TOPIC_ARN}" --region "$AWS_REGION" >/dev/null
fi

# Allow S3 to invoke Lambda
aws lambda add-permission   --function-name "$LAMBDA_NAME"   --statement-id s3invoke   --action lambda:InvokeFunction   --principal s3.amazonaws.com   --source-arn "arn:$AWS_PARTITION:s3:::${BUCKET_NAME}"   --region "$AWS_REGION" >/dev/null 2>&1 || true

# Wire S3 → Lambda (put on raw-images prefix)
aws s3api put-bucket-notification-configuration   --bucket "$BUCKET_NAME"   --notification-configuration "$(cat <<CONF
{ "LambdaFunctionConfigurations": [{
    "LambdaFunctionArn": "arn:$AWS_PARTITION:lambda:${AWS_REGION}:${ACCOUNT_ID}:function:${LAMBDA_NAME}",
    "Events": ["s3:ObjectCreated:*"],
    "Filter": { "Key": { "FilterRules": [{ "Name": "prefix", "Value": "raw-images/" }] } }
}]}
CONF
)" --region "$AWS_REGION"

# Simple alarm on Lambda errors >=1 (sends to email SNS)
bash "$SCRIPT_DIR/cw-alarms.sh" "$LAMBDA_NAME" "$TOPIC_ARN" "$AWS_REGION"

# Create EKS cluster (managed nodegroup)
eksctl create cluster --name "$EKS_CLUSTER" --region "$AWS_REGION" --nodes "$EKS_NODE_COUNT" --node-type "$EKS_NODE_TYPE" --with-oidc

kubectl create namespace image-pipeline --dry-run=client -o yaml | kubectl apply -f -

# Create a least-priv IAM user for the pod and store creds in a k8s Secret
USER_EXISTS=$(aws iam get-user --user-name "$EKS_IAM_USER_NAME" 2>/dev/null || true)
if [ -z "$USER_EXISTS" ]; then
  aws iam create-user --user-name "$EKS_IAM_USER_NAME" >/dev/null
fi
POL_ARN=$(aws iam list-policies --query 'Policies[?PolicyName==`image-pipeline-consumer`].Arn' --output text)
if [ -z "$POL_ARN" ]; then
  POL_ARN=$(aws iam create-policy --policy-name image-pipeline-consumer --policy-document file://$SCRIPT_DIR/iam-policies/eks-consumer-policy.json --query Policy.Arn --output text)
fi
aws iam attach-user-policy --user-name "$EKS_IAM_USER_NAME" --policy-arn "$POL_ARN" >/dev/null 2>&1 || true

# Access keys (create new each run; rotate manually if needed)
KEYS=$(aws iam create-access-key --user-name "$EKS_IAM_USER_NAME")
AWS_ACCESS_KEY_ID=$(echo "$KEYS" | jq -r .AccessKey.AccessKeyId)
AWS_SECRET_ACCESS_KEY=$(echo "$KEYS" | jq -r .AccessKey.SecretAccessKey)

kubectl -n image-pipeline delete secret aws-creds >/dev/null 2>&1 || true
kubectl -n image-pipeline create secret generic aws-creds   --from-literal=AWS_REGION="$AWS_REGION"   --from-literal=AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID"   --from-literal=AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"   --from-literal=QUEUE_URL="$QUEUE_URL"   --from-literal=BUCKET_NAME="$BUCKET_NAME"

# Render & apply manifests with ECR image URI
RENDERED="$(mktemp)"
sed "s#REPLACE_WITH_ECR_IMAGE_URI#${ECR_URI}#g" "$ROOT_DIR/eks-app/k8s/deployment.yaml" > "$RENDERED"
kubectl apply -f "$RENDERED"
kubectl apply -f "$ROOT_DIR/eks-app/k8s/service.yaml"
kubectl apply -f "$ROOT_DIR/eks-app/k8s/hpa.yaml" || true

echo
echo "=== SUCCESS ==="
echo "Bucket: $BUCKET_NAME"
echo "SNS Topic: $TOPIC_ARN"
echo "SQS Queue: $QUEUE_URL"
echo "ECR Image: $ECR_URI"
echo "Lambda: $LAMBDA_NAME"
echo "EKS Cluster: $EKS_CLUSTER"
echo
echo "Upload a test image:"
echo "  aws s3 cp ./sample.jpg s3://$BUCKET_NAME/raw-images/sample.jpg --region $AWS_REGION"
