#!/usr/bin/env bash
# cw-alarms.sh <lambdaName> <snsTopicArn> <region>
set -euo pipefail
LAMBDA_NAME="$1"
TOPIC_ARN="$2"
REGION="$3"

aws cloudwatch put-metric-alarm   --alarm-name "${LAMBDA_NAME}-ErrorsAlarm"   --metric-name Errors   --namespace AWS/Lambda   --statistic Sum   --period 60   --threshold 1   --comparison-operator GreaterThanOrEqualToThreshold   --dimensions Name=FunctionName,Value="$LAMBDA_NAME"   --evaluation-periods 1   --alarm-actions "$TOPIC_ARN"   --treat-missing-data notBreaching   --region "$REGION" >/dev/null
echo "Created CloudWatch alarm: ${LAMBDA_NAME}-ErrorsAlarm"
