import base64
import json
import os
from googleapiclient import discovery

def kill_switch(event, context):
    """Triggered by Pub/Sub budget alert at 95% threshold."""
    pubsub_message = base64.b64decode(event['data']).decode('utf-8')
    budget_data = json.loads(pubsub_message)

    cost_amount = budget_data.get('costAmount', 0)
    budget_amount = budget_data.get('budgetAmount', 0)

    if cost_amount / budget_amount >= 0.95:
        print(f"🚨 Budget at {cost_amount/budget_amount*100}% - initiating shutdown")

        compute = discovery.build('compute', 'v1')

        # Stop all instances
        project = os.environ['GCP_PROJECT']
        zones = ['us-central1-b', 'us-central1-c', 'us-central1-f']  # the cluster's actual zones

        for zone in zones:
            instances = compute.instances().list(project=project, zone=zone).execute()
            for instance in instances.get('items', []):
                if instance['status'] == 'RUNNING':
                    compute.instances().stop(
                        project=project, zone=zone, instance=instance['name']
                    ).execute()
                    print(f"Stopped: {instance['name']}")

        print("✅ Emergency shutdown complete")