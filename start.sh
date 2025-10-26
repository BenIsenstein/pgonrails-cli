#!/bin/bash
set -euo pipefail

if [ -f "./.env" ]; then
  source "./.env"
else
  echo "Error: .env file not found at .env"
  exit 1
fi

echo "Generating JWT secret and tokens for Supabase auth..."

base64_url_encode() { openssl enc -base64 -A | tr '+/' '-_' | tr -d '='; }

jwt_secret=$(openssl rand -hex 20)
header='{"alg": "HS256","typ": "JWT"}'
header_base64=$(printf %s "$header" | base64_url_encode)

# iat and exp for both tokens has to be same thats why initializing here
iat=$(date +%s)
exp=$(($iat + 5 * 3600 * 24 * 365)) # 5 years expiry

gen_token() {
    local payload=$(
        echo "$1" | jq --arg jq_iat "$iat" --arg jq_exp "$exp" '.iat=($jq_iat | tonumber) | .exp=($jq_exp | tonumber)'
    )

    local payload_base64=$(printf %s "$payload" | base64_url_encode)

    local signed_content="${header_base64}.${payload_base64}"

    local signature=$(printf %s "$signed_content" | openssl dgst -binary -sha256 -hmac "$jwt_secret" | base64_url_encode)

    printf '%s' "${signed_content}.${signature}"
}

anon_payload='{"role": "anon", "iss": "supabase"}'
anon_key=$(gen_token "$anon_payload")

service_payload='{"role": "service_role", "iss": "supabase"}'
service_key=$(gen_token "$service_payload")

echo "Fetching template info..."

# Fetch the default configuration from the API
default_config=$(curl --silent -X POST https://backboard.railway.com/graphql/v2 \
    -H "Accept: */*" \
    -H "Authorization: Bearer $RAILWAY_TOKEN" \
    -H "Content-Type: application/json" \
    -H "User-Agent: pgonrails-cli/0.0.1" \
    -d '{"query": "{ template(id: \"5e14ce66-9fb7-472e-ac44-15067d57cedc\") { serializedConfig } }"}'
)

# Initial template config JSON
requestBody='{
    "query": "mutation templateDeployV2($input: TemplateDeployV2Input!) {\n  templateDeployV2(input: $input) {\n    projectId\n    workflowId\n  }\n}",
    "variables": {
        "input": {
            "templateId": "5e14ce66-9fb7-472e-ac44-15067d57cedc",
            "serializedConfig": {
                "services": {}
            }
        }
    },
    "operationName": "templateDeployV2"
}'

echo "Generating template deployment config..."

while read -r serviceId serviceObj; do
    name=$(echo "$serviceObj" | jq -r '.name')

    requestBody=$(echo "$requestBody" | jq --arg serviceId "$serviceId" --argjson icon "$(echo "$serviceObj" | jq '.icon')" '.variables.input.serializedConfig.services[$serviceId].icon = $icon')
    requestBody=$(echo "$requestBody" | jq --arg serviceId "$serviceId" --argjson name "\"$name\"" '.variables.input.serializedConfig.services[$serviceId].name = $name')
    requestBody=$(echo "$requestBody" | jq --arg serviceId "$serviceId" --argjson deploy "$(echo "$serviceObj" | jq '.deploy')" '.variables.input.serializedConfig.services[$serviceId].deploy = $deploy')
    requestBody=$(echo "$requestBody" | jq --arg serviceId "$serviceId" --argjson source "$(echo "$serviceObj" | jq '.source')" '.variables.input.serializedConfig.services[$serviceId].source = $source')
    requestBody=$(echo "$requestBody" | jq --arg serviceId "$serviceId" --argjson networking "$(echo "$serviceObj" | jq '.networking')" '.variables.input.serializedConfig.services[$serviceId].networking = $networking')
    requestBody=$(echo "$requestBody" | jq --arg serviceId "$serviceId" --argjson volumeMounts "$(echo "$serviceObj" | jq '.volumeMounts')" '.variables.input.serializedConfig.services[$serviceId].volumeMounts = $volumeMounts')

    while read -r var varObj; do
        requestBody=$(echo "$requestBody" | jq --arg serviceId "$serviceId" --arg var "$var" --argjson value "$(echo "$varObj" | jq '.defaultValue')" '.variables.input.serializedConfig.services[$serviceId].variables[$var].value = $value')
    done < <(echo "$serviceObj" | jq -r '.variables | to_entries[] | "\(.key) \(.value | @json)"')

    if [ "$name" = "Postgres" ]; then
        requestBody=$(echo "$requestBody" | jq --arg serviceId "$serviceId" --argjson jwt_secret "\"$jwt_secret\"" '.variables.input.serializedConfig.services[$serviceId].variables.JWT_SECRET.value = $jwt_secret')
        requestBody=$(echo "$requestBody" | jq --arg serviceId "$serviceId" --argjson anon_key "\"$anon_key\"" '.variables.input.serializedConfig.services[$serviceId].variables.SUPABASE_ANON_KEY.value = $anon_key')
        requestBody=$(echo "$requestBody" | jq --arg serviceId "$serviceId" --argjson service_key "\"$service_key\"" '.variables.input.serializedConfig.services[$serviceId].variables.SUPABASE_SERVICE_KEY.value = $service_key')
    fi
done < <(echo "$default_config" | jq -r '.data.template.serializedConfig.services | to_entries[] | "\(.key) \(.value | @json)"')

echo "Deploying template..."

deployResult=$(curl --silent -X POST https://backboard.railway.com/graphql/v2 \
    -H "Accept: */*" \
    -H "Authorization: Bearer $RAILWAY_TOKEN" \
    -H "Content-Type: application/json" \
    -H "User-Agent: pgonrails-cli/0.0.1" \
    -d "$requestBody"
)

projectId=$(echo "$deployResult" | jq -r '.data.templateDeployV2.projectId')
workflowId=$(echo "$deployResult" | jq -r '.data.templateDeployV2.workflowId')

requestBody='{
    "query": "query workflowStatus($workflowId: String!) {\n  workflowStatus(workflowId: $workflowId) {\n    status\n    error\n  }\n}",
    "variables": {
        "workflowId": ""
    }
}'

requestBody=$(echo "$requestBody" | jq --arg workflowId "$workflowId" '.variables.workflowId = $workflowId')

echo "Creating project..."
echo ""

count=1
while true; do
    statusResult=$(curl --silent -X POST https://backboard.railway.com/graphql/v2 \
        -H "Accept: */*" \
        -H "Authorization: Bearer $RAILWAY_TOKEN" \
        -H "Content-Type: application/json" \
        -H "User-Agent: pgonrails-cli/0.0.1" \
        -d "$requestBody"
    )

    status=$(echo "$statusResult" | jq -r '.data.workflowStatus.status')
    error=$(echo "$statusResult" | jq -r '.data.workflowStatus.error')

    echo "Status #$count..."
    echo "-------------"
    echo "Status: $status"
    echo "Error: $error"
    echo ""

    if [ "$status" = "Complete" ]; then
        break
    fi

    if [ "$error" != "null" ] && [ "$error" != "" ]; then
        echo "Error detected: $error"
        break
    fi

    ((count++))
    sleep 1
done

requestBody='{
    "query": "query project($id: String!) { project(id: $id) { services { edges { node { id, name } } } } }",
    "variables": {
        "id": ""
    }
}'

requestBody=$(echo "$requestBody" | jq --arg id "$projectId" '.variables.id = $id')

echo "Fetching service IDs..."

servicesResult=$(curl --silent -X POST https://backboard.railway.com/graphql/v2 \
    -H "Accept: */*" \
    -H "Authorization: Bearer $RAILWAY_TOKEN" \
    -H "Content-Type: application/json" \
    -H "User-Agent: pgonrails-cli/0.0.1" \
    -d "$requestBody"
)

siteServiceId=$(echo "$servicesResult" | jq -r '.data.project.services.edges[] | select(.node.name == "Site") | .node.id')

requestBody='{
    "query": "query service($id: String!) { service(id: $id) { serviceInstances { edges { node { latestDeployment { status } } } } } }",
    "variables": {
        "id": ""
    }
}'

requestBody=$(echo "$requestBody" | jq --arg id "$siteServiceId" '.variables.id = $id')

echo "Waiting for service deployments to become healthy..."
echo ""

count=1
while true; do
    statusResult=$(curl --silent -X POST https://backboard.railway.com/graphql/v2 \
        -H "Accept: */*" \
        -H "Authorization: Bearer $RAILWAY_TOKEN" \
        -H "Content-Type: application/json" \
        -H "User-Agent: pgonrails-cli/0.0.1" \
        -d "$requestBody"
    )

    status=$(echo "$statusResult" | jq -r '.data.service.serviceInstances.edges[0].node.latestDeployment.status')
    
    echo "Poll for deployed services #$count..."
    echo "---------------------------------"
    echo "$status"
    echo ""

    if [[ -n "$status" && ( "$status" == "FAILED" || "$status" == "CRASHED" ) ]]; then
        echo "There has been a deployment error. Continuing..."
        break
    fi

    if [[ -n "$status" && "$status" == "SUCCESS" ]]; then
        echo "All services have deployed!"
        break
    fi

    ((count++))
    sleep 30
done

requestBody='{
  "query": "mutation templateServiceSourceEject($input: TemplateServiceSourceEjectInput!) {\n  templateServiceSourceEject(input: $input)\n}",
  "variables": {
    "input": {
      "upstreamUrl": "https://github.com/BenIsenstein/pgonrails",
      "repoName": "pgonrails",
      "repoOwner": "BenIsenstein",
      "serviceIds": [],
      "projectId": ""
    }
  },
  "operationName": "templateServiceSourceEject"
}'

requestBody=$(echo "$requestBody" | jq --arg id "$projectId" '.variables.input.projectId = $id')

requestBody=$(echo "$requestBody" | jq --argjson services "$servicesResult" '.variables.input.serviceIds = ($services.data.project.services.edges | map(.node.id))')

echo "Ejecting all services..."

ejectResult=$(curl --silent -X POST https://backboard.railway.com/graphql/v2 \
    -H "Accept: */*" \
    -H "Authorization: Bearer $RAILWAY_TOKEN" \
    -H "Content-Type: application/json" \
    -H "User-Agent: pgonrails-cli/0.0.1" \
    -d "$requestBody"
)

ejectSuccess=$(echo "$ejectResult" | jq -r '.data.templateServiceSourceEject')

if [[ "$ejectSuccess" == "true" ]]; then
    echo "Template ejected!"
else
    echo "Template failed to eject. Visit your project canvas to troubleshoot."
fi

requestBody='{
    "query": "query serviceInstances($projectId: String!) { project(id: $projectId) { environments { edges { node { serviceInstances { edges { node { serviceId, serviceName, rootDirectory } } } } } } } }",
    "variables": {
        "projectId": ""
    }
}'

requestBody=$(echo "$requestBody" | jq --arg projectId "$projectId" '.variables.projectId = $projectId')

echo "Fetching service instances for CI/CD config..."
echo ""

serviceInstancesResult=$(curl --silent -X POST https://backboard.railway.com/graphql/v2 \
    -H "Accept: */*" \
    -H "Authorization: Bearer $RAILWAY_TOKEN" \
    -H "Content-Type: application/json" \
    -H "User-Agent: pgonrails-cli/0.0.1" \
    -d "$requestBody"
)

requestBody='{
  "query": "mutation serviceInstanceUpdate($serviceId: String!, $input: ServiceInstanceUpdateInput!) {\n  serviceInstanceUpdate(serviceId: $serviceId, input: $input)\n}",
  "variables": {
    "serviceId": "",
    "input": {
      "watchPatterns": []
    }
  }
}'

while read -r service; do
    serviceName=$(echo "$service" | jq -r '.serviceName')
    serviceId=$(echo "$service" | jq -r '.serviceId')
    rootDir=$(echo "$service" | jq -r '.rootDirectory')

    echo "Updating CI/CD watch patterns for \"$serviceName\"..."
    
    requestBody=$(echo "$requestBody" | jq --arg serviceId "$serviceId" '.variables.serviceId = $serviceId')
    requestBody=$(echo "$requestBody" | jq --argjson watchPatterns "[\"$rootDir/**/*\"]" '.variables.input.watchPatterns = $watchPatterns')

    result=$(curl --silent -X POST https://backboard.railway.com/graphql/v2 \
        -H "Accept: */*" \
        -H "Authorization: Bearer $RAILWAY_TOKEN" \
        -H "Content-Type: application/json" \
        -H "User-Agent: pgonrails-cli/0.0.1" \
        -d "$requestBody"
    )

    success=$(echo "$result" | jq -r '.data.serviceInstanceUpdate')

    if [[ "$success" == "false" ]]; then
        echo "Update failed for \"$serviceName\". Visit your project canvas to troubleshoot."
    fi

done < <(echo "$serviceInstancesResult" | jq -c '.data.project.environments.edges[0].node.serviceInstances.edges[].node')

requestBody='{
    "query": "query service($id: String!) { service(id: $id) { serviceInstances { edges { node { source { repo } } } } } }",
    "variables": {
        "id": ""
    }
}'

requestBody=$(echo "$requestBody" | jq --arg id "$siteServiceId" '.variables.id = $id')

echo ""
echo "Fetching new GitHub repo url..."

newRepoResult=$(curl --silent -X POST https://backboard.railway.com/graphql/v2 \
    -H "Accept: */*" \
    -H "Authorization: Bearer $RAILWAY_TOKEN" \
    -H "Content-Type: application/json" \
    -H "User-Agent: pgonrails-cli/0.0.1" \
    -d "$requestBody"
)

repo=$(echo "$newRepoResult" | jq -r '.data.service.serviceInstances.edges[0].node.source.repo')

echo ""
echo "New GitHub repo: "
echo "https://github.com/$repo"

echo ""
echo "New Railway project: "
echo "https://railway.com/project/$projectId"

echo ""
echo "Thank you for using PG On Rails CLI. Happy hacking!"
