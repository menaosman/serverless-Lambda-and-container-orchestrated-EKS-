#!/usr/bin/env bash
set -euo pipefail

export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
export AWS_ENDPOINT_URL="http://localhost:4566"

BUCKET_NAME="image-pipeline-local"
TOPIC_NAME="image-keys-topic"
QUEUE_NAME="image-keys-queue"

echo ">> Creating resources on LocalStack..."
aws --endpoint-url $AWS_ENDPOINT_URL s3api create-bucket --bucket "$BUCKET_NAME" >/dev/null || true

TOPIC_ARN=$(aws --endpoint-url $AWS_ENDPOINT_URL sns create-topic --name "$TOPIC_NAME" --query TopicArn --output text)
QUEUE_URL=$(aws --endpoint-url $AWS_ENDPOINT_URL sqs create-queue --queue-name "$QUEUE_NAME" --query QueueUrl --output text)
QUEUE_ARN=$(aws --endpoint-url $AWS_ENDPOINT_URL sqs get-queue-attributes --queue-url "$QUEUE_URL" --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)

aws --endpoint-url $AWS_ENDPOINT_URL sns subscribe   --topic-arn "$TOPIC_ARN"   --protocol sqs   --notification-endpoint "$QUEUE_ARN"   --attributes RawMessageDelivery=true >/dev/null

aws --endpoint-url $AWS_ENDPOINT_URL sqs set-queue-attributes --queue-url "$QUEUE_URL" --attributes "Policy=$(cat <<POL
{ "Version": "2012-10-17", "Statement": [{
  "Sid": "Allow-SNS",
  "Effect": "Allow",
  "Principal": {"Service": "sns.amazonaws.com"},
  "Action": "sqs:SendMessage",
  "Resource": "$QUEUE_ARN",
  "Condition": {"ArnEquals": {"aws:SourceArn": "$TOPIC_ARN"}}
}]}
POL
)" >/dev/null

echo ">> Simulating Lambda publish (without Lambda runtime, just SNS publish)..."
MSG='{"bucket":"'"$BUCKET_NAME"'","key":"raw-images/sample.jpg"}'
aws --endpoint-url $AWS_ENDPOINT_URL sns publish --topic-arn "$TOPIC_ARN" --message "$MSG" >/dev/null

echo ">> Uploading a dummy file to S3 (raw-images/sample.jpg)..."
echo "hello" > sample.jpg
aws --endpoint-url $AWS_ENDPOINT_URL s3 cp sample.jpg s3://$BUCKET_NAME/raw-images/sample.jpg >/dev/null

echo ">> Receiving the message from SQS (shows the body with bucket/key)"
aws --endpoint-url $AWS_ENDPOINT_URL sqs receive-message --queue-url "$QUEUE_URL" --wait-time-seconds 2 --max-number-of-messages 1

echo ">> Done. In real AWS, the EKS consumer pod pulls from SQS, reads S3, and writes thumbnails/"
