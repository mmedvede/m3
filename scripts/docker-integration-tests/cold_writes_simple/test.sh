#!/usr/bin/env bash

set -xe

source $GOPATH/src/github.com/m3db/m3/scripts/docker-integration-tests/common.sh
REVISION=$(git rev-parse HEAD)

echo "Run m3dbnode docker container"

CONTAINER_NAME="m3dbnode-version-${REVISION}"
docker create --name "${CONTAINER_NAME}" -p 9000:9000 -p 9001:9001 -p 9002:9002 -p 9003:9003 -p 9004:9004 -p 7201:7201 "m3dbnode_integration:${REVISION}"

# think of this as a defer func() in golang
function defer {
  echo "Test complete, dumping logs"
  echo "---------------------------"
  docker logs "${CONTAINER_NAME}"
  echo "---------------------------"

  echo "Removing docker container"
  docker rm --force "${CONTAINER_NAME}"
}
trap defer EXIT

docker start "${CONTAINER_NAME}"

# TODO(rartoul): Rewrite this test to use a docker-compose file like the others so that we can share all the
# DB initialization logic with the setup_single_m3db_node command in common.sh like the other files. Right now
# we can't do that because this test doesn't use the docker-compose networking so we have to specify 127.0.0.1
# as the endpoint in the placement instead of being able to use dbnode01.
echo "Wait for DB to be up"
ATTEMPTS=10 MAX_TIMEOUT=4 TIMEOUT=1 retry_with_backoff  \
  'curl -vvvsSf 0.0.0.0:9002/bootstrappedinplacementornoplacement'

echo "Wait for coordinator API to be up"
ATTEMPTS=10 MAX_TIMEOUT=4 TIMEOUT=1 retry_with_backoff  \
  'curl -vvvsSf 0.0.0.0:7201/health'

echo "Adding namespace"
curl -vvvsSf -X POST 0.0.0.0:7201/api/v1/namespace -d '{
  "name": "unagg",
  "options": {
    "bootstrapEnabled": true,
    "flushEnabled": true,
    "writesToCommitLog": true,
    "cleanupEnabled": true,
    "snapshotEnabled": true,
    "repairEnabled": false,
    "coldWritesEnabled": true,
    "retentionOptions": {
      "retentionPeriodDuration": "8h",
      "blockSizeDuration": "2h",
      "bufferFutureDuration": "10m",
      "bufferPastDuration": "10m",
      "blockDataExpiry": true,
      "blockDataExpiryAfterNotAccessPeriodDuration": "5m"
    }
  }
}'

echo "Sleep until namespace is init'd"
ATTEMPTS=4 TIMEOUT=1 retry_with_backoff  \
  '[ "$(curl -sSf 0.0.0.0:7201/api/v1/namespace | jq .registry.namespaces.unagg.indexOptions.enabled)" == false ]'

echo "Placement initialization"
curl -vvvsSf -X POST 0.0.0.0:7201/api/v1/placement/init -d '{
    "num_shards": 4,
    "replication_factor": 1,
    "instances": [
        {
            "id": "m3db_local",
            "isolation_group": "rack-a",
            "zone": "embedded",
            "weight": 1024,
            "endpoint": "127.0.0.1:9000",
            "hostname": "127.0.0.1",
            "port": 9000
        }
    ]
}'

echo "Sleep until placement is init'd"
ATTEMPTS=4 TIMEOUT=1 retry_with_backoff  \
  '[ "$(curl -sSf 0.0.0.0:7201/api/v1/placement | jq .placement.instances.m3db_local.id)" == \"m3db_local\" ]'

echo "Sleep until bootstrapped"
ATTEMPTS=7 TIMEOUT=2 retry_with_backoff  \
  '[ "$(curl -sSf 0.0.0.0:9002/health | jq .bootstrapped)" == true ]'

echo "Waiting until shards are marked as available"
ATTEMPTS=10 TIMEOUT=1 retry_with_backoff  \
  '[ "$(curl -sSf 0.0.0.0:7201/api/v1/placement | grep -c INITIALIZING)" -eq 0 ]'

echo "Write data for 'now - 2 * bufferPast'"
curl -vvvsS -X POST 0.0.0.0:9003/write -d '{
  "namespace": "unagg",
  "id": "foo",
  "datapoint": {
    "timestamp":'"$(($(date +"%s") - 60 * 20))"',
    "value": 12.3456789
  }
}'

echo "Read data (not using index)"
queryResult=$(curl -sSf -X POST 0.0.0.0:9003/fetch -d '{
  "namespace": "unagg",
  "id": "foo",
  "rangeStart": 0,
  "rangeEnd":'"$(date +"%s")"'
}' | jq '.datapoints | length')

if [ "$queryResult" -lt 1 ]; then
  echo "Result not found"
  exit 1
else
  echo "Result found"
fi

echo "Write data for 'now - 2 * blockSize'"
curl -vvvsS -X POST 0.0.0.0:9003/write -d '{
  "namespace": "unagg",
  "id": "foo",
  "datapoint": {
    "timestamp":'"$(($(date +"%s") - 60 * 60 * 4))"',
    "value": 98.7654321
  }
}'

echo "Wait until cold writes are flushed"
ATTEMPTS=10 MAX_TIMEOUT=4 TIMEOUT=1 retry_with_backoff  \
  '[ -n "$(docker exec -it "${CONTAINER_NAME}" find /var/lib/m3db/data/ -name "*1-checkpoint.db")" ]'

echo "Restart DB to test reading cold writes from disk"
docker restart "${CONTAINER_NAME}"

echo "Wait for DB to be up"
ATTEMPTS=10 MAX_TIMEOUT=4 TIMEOUT=1 retry_with_backoff  \
  'curl -vvvsSf 0.0.0.0:9002/bootstrappedinplacementornoplacement'

echo "Wait for coordinator API to be up"
ATTEMPTS=10 MAX_TIMEOUT=4 TIMEOUT=1 retry_with_backoff  \
  'curl -vvvsSf 0.0.0.0:7201/health'

echo "Sleep until bootstrapped"
ATTEMPTS=7 TIMEOUT=2 retry_with_backoff  \
  '[ "$(curl -sSf 0.0.0.0:9002/health | jq .bootstrapped)" == true ]'

echo "Waiting until shards are marked as available"
ATTEMPTS=10 TIMEOUT=1 retry_with_backoff  \
  '[ "$(curl -sSf 0.0.0.0:7201/api/v1/placement | grep -c INITIALIZING)" -eq 0 ]'

echo "Read data (not using index)"
queryResult=$(curl -sSf -X POST 0.0.0.0:9003/fetch -d '{
  "namespace": "unagg",
  "id": "foo",
  "rangeStart": 0,
  "rangeEnd":'"$(date +"%s")"'
}' | jq '.datapoints | length')

if [ "$queryResult" -lt 2 ]; then
  echo "Found fewer than expected results"
  exit 1
else
  echo "Expected result found"
fi

echo "Deleting placement"
curl -vvvsSf -X DELETE 0.0.0.0:7201/api/v1/placement

echo "Deleting namespace"
curl -vvvsSf -X DELETE 0.0.0.0:7201/api/v1/namespace/unagg