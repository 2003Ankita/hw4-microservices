import os
from google.cloud import pubsub_v1

PROJECT_ID = os.environ.get("PROJECT_ID", "sustained-flow-485619-g3")
SUBSCRIPTION_NAME = os.environ.get("SUBSCRIPTION_NAME", "hw4-forbidden-sub")

subscriber = pubsub_v1.SubscriberClient()
subscription_path = subscriber.subscription_path(PROJECT_ID, SUBSCRIPTION_NAME)

print("Listening for banned country requests...")

def callback(message):
    data = message.data.decode("utf-8")
    print(f"Received message: {data}")

    # OPTIONAL: extract country nicely
    if "country" in data:
        print(f"Forbidden request from banned country detected")

    message.ack()

# THIS LINE IS THE MOST IMPORTANT
streaming_pull_future = subscriber.subscribe(subscription_path, callback=callback)

try:
    streaming_pull_future.result()
except KeyboardInterrupt:
    streaming_pull_future.cancel()