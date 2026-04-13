import requests
import time
from collections import defaultdict
from datetime import datetime

LOAD_BALANCER_IP = "34.182.95.68"  # Replace if needed
PORT = 8080
URL = f"http://{LOAD_BALANCER_IP}:{PORT}/"

zone_counts = defaultdict(int)
start_time = datetime.now()

print("Sending requests to the load balancer once per second...")
print("Press Ctrl+C to stop.\n")

try:
    while True:
        timestamp = datetime.now().strftime("%H:%M:%S")
        try:
            response = requests.get(URL, timeout=10)
            zone = response.headers.get("X-Zone", "Unknown")
            zone_counts[zone] += 1
            print(f"[{timestamp}] Status: {response.status_code}, Zone: {zone}")
        except requests.exceptions.RequestException as e:
            print(f"[{timestamp}] ERROR: {e}")
        time.sleep(1)

except KeyboardInterrupt:
    end_time = datetime.now()
    duration = (end_time - start_time).total_seconds()

    print("\nClient stopped.")
    print(f"Total Duration: {duration:.2f} seconds")
    print("\nRequests served by each zone:")

    total_requests = sum(zone_counts.values())
    for zone, count in zone_counts.items():
        ratio = (count / total_requests) * 100 if total_requests else 0
        print(f"{zone}: {count} requests ({ratio:.2f}%)")