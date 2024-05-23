resource "biganimal_cluster" "instance" {
    for_each = local.use_wal_volume || local.use_pgd ? {} : local.data_groups
    # required
    cloud_provider = each.value.cloud_provider_id
    cluster_architecture {
        id = each.value.type
        nodes = each.value.node_count
    }
    cluster_name = local.cluster_name
    instance_type = each.value.instance_type
    password = local.password
    pg_type = each.value.engine
    pg_version = each.value.engine_version
    pgvector = each.value.pgvector
    project_id = var.project.id
    region = each.value.region
    storage {
        volume_type = each.value.volume.type
        volume_properties = each.value.volume.properties
        size = each.value.volume_size
        # optional
        iops = each.value.volume.iops
        throughput = each.value.volume.throughput
    }

    # optional
    dynamic "allowed_ip_ranges" {
        for_each = each.value.allowed_ip_ranges
        content {
            cidr_block = allowed_ip_ranges.value.cidr_block
            description = allowed_ip_ranges.value.description
        }
    }
    backup_retention_period = "1d"
    csp_auth = false
    dynamic "pg_config" {
        for_each = { for key,values in each.value.settings: key=>values }
        content {
            name         = pg_config.value.name
            value        = pg_config.value.value
        }
    }
    private_networking = !var.publicly_accessible
    read_only_connections = false
    superuser_access = each.value.superuser_access
}

resource "biganimal_pgd" "clusters" {
    count = local.use_wal_volume || !local.use_pgd ? 0 : 1

    # required
    cluster_name = local.cluster_name
    project_id = var.project.id
    password = local.password

    data_groups = [
      for key, values in local.data_groups: {
        cloud_provider = {
          cloud_provider_id = values.cloud_provider_id
        }
        cluster_architecture = {
            cluster_architecture_id = values.type
            nodes = values.node_count
        }
        instance_type = { 
          instance_type_id = values.instance_type
        }
        pg_type = {
          pg_type_id = values.engine
        }
        pg_version = {
          pg_version_id = values.engine_version
        }
        project_id = var.project.id
        region = {
          region_id = values.region
        }
        storage = {
            volume_type = values.volume.type
            volume_properties = values.volume.properties
            size = values.volume_size
            # optional
            iops = values.volume.iops
            throughput = values.volume.throughput
        }

        maintenance_window = {
          is_enabled = false
          start_day  = 0
          start_time = "00:00"
        }

        # optional
        allowed_ip_ranges = [
          for k, range_values in values.allowed_ip_ranges: {
            cidr_block = range_values.cidr_block
            description = range_values.description
          }
        ]
        pg_config = [
          for k, config_values in values.settings: {
            name         = config_values.name
            value        = config_values.value
          }
        ]

        pe_allowed_principled_ids = []
        service_account_ids = contains(["gcp"], var.cloud_provider) ? [] : null

        backup_retention_period = "1d"
        csp_auth = false
        private_networking = !var.publicly_accessible
        read_only_connections = false
        superuser_access = values.superuser_access
      }
    ]

    witness_groups = [
      for k,v in var.witness_groups: {
        region = {
          region_id = v.region
        }
        cloud_provider = {
          cloud_provider_id = v.cloud_account ? v.cloud_service_provider : "bah:${v.cloud_service_provider}"
        }
        maintenance_window = {
          is_enabled = v.maintenance_window.is_enabled
          start_day = v.maintenance_window.start_day
          start_time = v.maintenance_window.start_time
        }
      }
    ]

  lifecycle {
    precondition {
      error_message = "Witness group must be set when using 2 data groups with pgd"
      condition = length(local.data_groups) <= 1 || length(var.witness_groups) > 0
    }
  }
}

resource "toolbox_external" "api" {
  count = local.use_wal_volume ? 1 : 0
  create = true
  read = false
  update = false
  delete = true
  program = [
    "bash",
    "-c",
    <<EOT
    set -eou pipefail

    URI="$${BA_API_URI:=https://portal.biganimal.com/api/v3/}"

    create_stage() {
      ENDPOINT="projects/${var.project.id}/clusters"
      REQUEST_TYPE="POST"
      DATA='${jsonencode(local.API_DATA)}'
      RESULT=$(curl --silent --show-error --fail-with-body --location --request $REQUEST_TYPE --header "content-type: application/json" --header "$AUTH_HEADER" --url "$URI$ENDPOINT" --data "$DATA")
      RC=$?
      if [[ $RC -ne 0 ]];
      then
        printf "%s\n" "$RESULT" 1>&2
        exit $RC
      fi

      CLUSTER_DATA=$RESULT

      # Check cluster status
      ENDPOINT="projects/${var.project.id}/clusters/$(printf %s "$CLUSTER_DATA" | jq -r .data.clusterId)"
      REQUEST_TYPE="GET"
      PHASE="creating"
      # Wait 30 minutes for cluster to be healthy
      COUNT=0
      COUNT_LIMIT=120
      SLEEP_TIME=15
      while [[ $PHASE != *"healthy"* ]]
      do
        RESULT=$(curl --silent --show-error --fail-with-body --location --request $REQUEST_TYPE --header "content-type: application/json" --header "$AUTH_HEADER" --url "$URI$ENDPOINT")
        RC=$?
        if [[ $RC -ne 0 ]]
        then
          printf "%s\n" "$RESULT" 1>&2
          exit $RC
        fi
        PHASE=$(printf "$RESULT" | jq -r .data.phase)

        if [[ $COUNT -gt COUNT_LIMIT ]] && [[ $PHASE != *"healthy"* ]]
        then
          printf "Cluster creation timed out\n" 1>&2
          printf "Last phase: $PHASE\n" 1>&2
          printf "Cluster data: $CLUSTER_DATA\n" 1>&2
          exit 1
        fi

        COUNT=$((COUNT+1))
        sleep $SLEEP_TIME
      done

      printf "$RESULT"
    }

    delete_stage() {
      ENDPOINT="projects/${var.project.id}/clusters/$1"
      REQUEST_TYPE="DELETE"
      RESULT=$(curl --silent --show-error --fail-with-body --location --request $REQUEST_TYPE --header "content-type: application/json" --header "$AUTH_HEADER" --url "$URI$ENDPOINT")
      RC=$?
      if [[ $RC -ne 0 ]];
      then
        printf "%s\n" "$RESULT" 1>&2
        exit $RC
      fi

      printf '{"done":"%s"}' "$RESULT"
    }

    # Get json object from stdin
    IFS='' read -r input || [ -n "$input" ]

    # BigAnimal API accepts either an access key or a bearer token
    # The access token should be preferred if set and non-empty.
    AUTH_HEADER=""
    if [ ! -z "$${BA_ACCESS_KEY:+''}" ]
    then
      AUTH_HEADER="x-access-key: $BA_ACCESS_KEY"
    else
      AUTH_HEADER="authorization: Bearer $BA_BEARER_TOKEN"
    fi

    # Check CRUD stage from terraform
    # and make appropriate calls
    STAGE=$(printf "%s" "$input" | jq -r '.stage')
    case $STAGE in
      create)
        create_stage
        ;;
      read)
        ;;
      update)
        ;;
      delete)
        CLUSTER_ID=$(printf "%s" "$input" | jq -r '.old_result.data.clusterId')
        delete_stage "$CLUSTER_ID"
        ;;
      *)
        printf "Input: %s\n" "$input" 1>&2
        printf "Invalid stage: %s\n" "$STAGE" 1>&2
        exit 1
        ;;
    esac

    EOT
  ]
}

locals {
  cluster_output = try(jsondecode(toolbox_external.api.0.result.data), biganimal_pgd.clusters.0, one(values(biganimal_cluster.instance)))
  cluster_region = try(local.cluster_output.region.regionId, local.cluster_output.region, local.cluster_output.data_groups.*.region.region_id)
  cluster_id = try(local.cluster_output.clusterId, local.cluster_output.cluster_id)
  /*
  BigAnimal does not output the VPC id as it shares a VPC for all clusters within a project
  - Currently it has the following VPC name format: vpc-<project_id>-<region>
  - the resource will contain the project id: prj_<project_id>
  */
  base_project_id = trimprefix(var.project.id, "prj_")
  vpc_name = try(format("vpc-%s-%s", local.base_project_id, local.cluster_region), "unknown")
  vpc_cmd = try("aws ec2 describe-vpcs --filter Name=tag:Name,Values=${local.vpc_name} --query Vpcs[] --output json --region ${local.cluster_region}", "")
  extract_vpc_id = "jq -r .[].VpcId"
  extract_biganimal_id = "jq -r '.[].Tags[] | select(.Key == \"BAID\") | .Value'"

  /*
  BigAnimal creates 3 buckets. 2 are accessible with a private endpoint after being activated on the account.
  When using a cloud_account, we can attempt to find the buckets
  */
  // postgres bucket - pg-bucket-<project_id>-<region>/<cluster_id>/
  // Will contain base and wals directory
  postgres_bucket = try(format("pg-bucket-%s-%s", local.base_project_id, local.cluster_region), "unknown")
  postgres_bucket_prefix = local.cluster_id
  // container logs bucket will need to be queried as each node will have a different directory suffix
  // Bucket may not not be available for some time after provisioning completes
  container_bucket = try(format("logs-bucket-%s-%s", local.base_project_id, local.cluster_region), "unknown")
  partial_container_prefix = try(format("kubernetes-logs/customer_postgresql_cluster.var.log.containers.%s", local.cluster_id), "unknown")
  // metrics logs bucket
  // directory prefix unknown
  metrics_bucket = try(format("metrics-bucket-%s-%s", local.base_project_id, local.cluster_region), "unknown")
}
