#!/bin/bash

# Stop and remove the Filebeat container if it exists
if [ "$(docker ps -aq -f name=filebeat)" ]; then
    echo "Stopping and removing existing Filebeat container..."
    docker stop filebeat
    docker rm filebeat
else
    echo "No existing Filebeat container found. Skipping stop and remove."
fi

echo "Filebeat container stopped and removed."