# Serverless → Kubernetes Image Processing Pipeline (S3 → Lambda → SNS → SQS → EKS)

**Goal:** Stitch together serverless (Lambda) and container-orchestrated (EKS) services into a single, observable workflow.

## Architecture (1 page)
- S3 (`raw-images/`) upload event → **Lambda** (Node.js, <100 LOC) → publishes object key to **SNS**.
- **SQS** subscribed to SNS (raw delivery).
- **EKS** consumer (Node.js service, Docker image <200MB) polls SQS, resizes image (Sharp), writes to the same bucket under `thumbnails/`.
- **CloudWatch**: see Lambda trigger logs and EKS consumer logs; basic error alarm to SNS Email.
- **IaC**: concise bash (AWS CLI + eksctl + kubectl). Teardown included.

> See `architecture-diagram.png` as a blank placeholder—open in draw.io/Excalidraw and sketch this exact flow with minimal boxes and arrows, plus IAM roles.

---

## Requirements
- AWS account with rights to create S3, Lambda, SNS, SQS, ECR, EKS, IAM, and ALB (ALB is not strictly required for this demo).
- Local: `awscli`, `docker`, `kubectl`, `eksctl`, `jq`.
- Node.js ≥ 18.
- Region defaults to `us-east-1`. Override via `.env` or environment variables.

---

## Quick Start

### 0) Configure
Copy `.env.example` to `.env` and edit values:
```bash
cp .env.example .env
```

### 1) Deploy everything
```bash
cd infra
bash create.sh
```
This will:
- Create S3 bucket, SNS topic, SQS queue and subscribe SQS to SNS.
- Build and push the EKS app Docker image to ECR.
- Package & deploy the Lambda, wire S3 → Lambda notification.
- Create an EKS cluster (1× t3.small), a minimal IAM *user* with least-priv permissions for the pod, store keys in a K8s Secret, and deploy the consumer (Deployment + Service + optional HPA).

> **Note:** Using an IAM *user* in a demo keeps IRSA complexity out. For production, replace with IRSA (service account + OIDC + role).

### 2) Test
- Upload any `.jpg/.png` to the bucket’s `raw-images/` prefix:
```bash
aws s3 cp ./sample.jpg s3://$BUCKET_NAME/raw-images/sample.jpg --region $AWS_REGION
```
- Within ~30 seconds the EKS service writes `thumbnails/sample.jpg`.
- Check logs:
  - Lambda: CloudWatch Logs → `/aws/lambda/$LAMBDA_NAME`
  - EKS app: `kubectl logs deploy/image-consumer -n image-pipeline`
- (Optional) Generate a pre-signed URL to view the thumbnail:
```bash
aws s3 presign s3://$BUCKET_NAME/thumbnails/sample.jpg --expires-in 3600 --region $AWS_REGION
```

### 3) Teardown
```bash
cd infra
bash destroy.sh
```

---

## Repo Layout
```
.
├─ README.md
├─ architecture-diagram.png      # blank placeholder
├─ .env.example
├─ lambda/
│  ├─ index.js
│  └─ package.json
├─ eks-app/
│  ├─ Dockerfile
│  ├─ package.json
│  └─ src/index.js
├─ eks-app/k8s/
│  ├─ deployment.yaml
│  ├─ service.yaml
│  └─ hpa.yaml                   # optional
└─ infra/
   ├─ create.sh
   ├─ destroy.sh
   ├─ cw-alarms.sh
   └─ iam-policies/
      ├─ eks-consumer-policy.json
      └─ lambda-publish-policy.json
```

---

## Notes / Limits
- Docker image uses `node:18-bookworm-slim` + `npm ci --omit=dev` to stay below ~180MB.
- Lambda is < 100 LOC and uses SNS v3 SDK.
- Security: demo uses least-priv IAM *user* creds in a K8s Secret. For production use IRSA.
- Alarms: a simple `Errors >= 1` alarm on the Lambda sends to your SNS email subscription.
