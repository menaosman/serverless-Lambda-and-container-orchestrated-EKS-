import { SNSClient, PublishCommand } from "@aws-sdk/client-sns";

const sns = new SNSClient({ region: process.env.AWS_REGION });
const topicArn = process.env.TOPIC_ARN;

// S3 Put event → publish object key to SNS
export const handler = async (event) => {
  try {
    // Grab first record (one object per event in this demo)
    const rec = event?.Records?.[0];
    if (!rec) throw new Error("No S3 record");
    const key = decodeURIComponent(rec.s3.object.key);
    const bucket = rec.s3.bucket.name;

    const msg = JSON.stringify({ bucket, key });
    await sns.send(new PublishCommand({
      TopicArn: topicArn,
      Message: msg
    }));

    console.log("Published to SNS:", msg);
    return { statusCode: 200, body: "OK" };
  } catch (err) {
    console.error("Lambda error:", err);
    throw err;
  }
};
