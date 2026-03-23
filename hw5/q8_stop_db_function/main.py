import os
from googleapiclient import discovery

PROJECT_ID = os.environ.get("PROJECT_ID")
INSTANCE_ID = os.environ.get("INSTANCE_ID")

def stop_sql_instance(event, context):
    service = discovery.build("sqladmin", "v1", cache_discovery=False)

    instance = service.instances().get(
        project=PROJECT_ID,
        instance=INSTANCE_ID
    ).execute()

    current_policy = instance["settings"].get("activationPolicy", "ALWAYS")

    if current_policy == "NEVER":
        print(f"Instance {INSTANCE_ID} is already stopped.")
        return

    body = {
        "settings": {
            "activationPolicy": "NEVER"
        }
    }

    result = service.instances().patch(
        project=PROJECT_ID,
        instance=INSTANCE_ID,
        body=body
    ).execute()

    print(f"Stop request submitted for instance {INSTANCE_ID}.")
    print(result)
