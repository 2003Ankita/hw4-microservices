import os
import json
from google.cloud import pubsub_v1

PROJECT_ID = os.environ.get("PROJECT_ID", "sustained-flow-485619-g3")
SUBSCRIPTION_NAME = os.environ.get("SUBSCRIPTION_NAME", "hw4-forbidden-sub")

subscriber = pubsub_v1.SubscriberClient()
subscription_path = subscriber.subscription_path(PROJECT_ID, SUBSCRIPTION_NAME)

print("Listening for banned country requests...\n")

def callback(message):
    try:
        data = json.loads(message.data.decode("utf-8"))
        country = data.get("country", "Unknown")
        print(f"Forbidden request from banned country: {country}")
    except Exception as e:
        print("Error processing message:", e)

    message.ack()

subscriber.subscribe(subscription_path, callback=callback)

# Keep the program running
import time
while True:
    time.sleep(10)