import { SQSClient, ReceiveMessageCommand, DeleteMessageCommand, ChangeMessageVisibilityCommand } from "@aws-sdk/client-sqs";
import { S3Client, GetObjectCommand, PutObjectCommand } from "@aws-sdk/client-s3";
import sharp from "sharp";

const region = process.env.AWS_REGION;
const queueUrl = process.env.QUEUE_URL;
const bucket = process.env.BUCKET_NAME;
const concurrency = parseInt(process.env.WORKERS || "2", 10);

const sqs = new SQSClient({ region });
const s3 = new S3Client({ region });

async function resizeImage(buffer) {
  // Resize to 256px width, keep aspect ratio; output JPEG
  return await sharp(buffer).resize({ width: 256 }).jpeg({ quality: 80 }).toBuffer();
}

async function processMessage(msg) {
  try {
    const body = JSON.parse(msg.Body);
    // If SNS to SQS (raw delivery), body is our JSON
    const { bucket: b, key } = body;
    console.log("Processing", b, key);

    const getObj = await s3.send(new GetObjectCommand({ Bucket: b, Key: key }));
    const bytes = Buffer.from(await getObj.Body.transformToByteArray());
    const out = await resizeImage(bytes);

    const thumbKey = key.replace(/^raw-images\//, "thumbnails/");
    await s3.send(new PutObjectCommand({
      Bucket: b,
      Key: thumbKey,
      Body: out,
      ContentType: "image/jpeg"
    }));

    console.log("Wrote thumbnail to s3://%s/%s", b, thumbKey);

    await sqs.send(new DeleteMessageCommand({
      QueueUrl: queueUrl,
      ReceiptHandle: msg.ReceiptHandle
    }));
  } catch (err) {
    console.error("Worker error:", err);
    // extend visibility to retry later
    try {
      await sqs.send(new ChangeMessageVisibilityCommand({
        QueueUrl: queueUrl,
        ReceiptHandle: msg.ReceiptHandle,
        VisibilityTimeout: 60
      }));
    } catch {}
  }
}

async function pollLoop(id) {
  console.log("Worker %d started", id);
  while (true) {
    try {
      const resp = await sqs.send(new ReceiveMessageCommand({
        QueueUrl: queueUrl,
        MaxNumberOfMessages: 1,
        WaitTimeSeconds: 20,
        VisibilityTimeout: 30
      }));
      if (resp.Messages && resp.Messages.length) {
        await processMessage(resp.Messages[0]);
      }
    } catch (e) {
      console.error("Poll error:", e);
      await new Promise(r => setTimeout(r, 2000));
    }
  }
}

for (let i=0; i<concurrency; i++) {
  pollLoop(i+1);
}
