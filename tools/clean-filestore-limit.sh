#!/bin/bash
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -e -o pipefail

BUILD_ID=${BUILD_ID:-non-existent-build}
PROJECT_ID=${PROJECT_ID:-$(gcloud config get-value project)}
# Supports DRY_RUN passed from YAML (defaults to false if run directly)
DRY_RUN=${DRY_RUN:-false}

if [ -z "$PROJECT_ID" ]; then
	echo "ERROR: PROJECT_ID must be defined"
	exit 1
fi

CLEANUP_AGE_SECONDS=$((24 * 60 * 60))
CURRENT_TIME=$(date +%s)
KEPT_ACTIVE_INSTANCE=false

echo "=========================================================="
echo "Starting Filestore & Peering Cleanup: ${PROJECT_ID}"
echo "DRY_RUN Mode : ${DRY_RUN}"
if [ "$DRY_RUN" = "true" ]; then
	echo ">> (SIMULATION ONLY: No resources will actually be deleted) <<"
fi
echo "=========================================================="

# =================================================================
# 1. FILESTORE INSTANCES CLEANUP
# =================================================================
# Fetch full resource path and createTime
FILESTORE_INSTANCES=$(gcloud filestore instances list \
	--project "${PROJECT_ID}" \
	--format="value(name,createTime)" 2>/dev/null || true)

if [[ -n "$FILESTORE_INSTANCES" ]]; then
	while read -r full_name create_time; do
		[[ -z "$full_name" ]] && continue

		# Correctly parse instance name and location from full URI:
		# projects/<proj>/locations/<location>/instances/<instance>
		instance=$(basename "${full_name}")
		location=$(echo "${full_name}" | cut -d/ -f4)

		create_time_seconds=$(date -d "$create_time" +%s 2>/dev/null || echo 0)
		age_seconds=$((CURRENT_TIME - create_time_seconds))
		age_hours=$((age_seconds / 3600))

		echo ""
		echo "----------------------------------------------------"
		echo "Filestore : ${instance}"
		echo "Location  : ${location}"
		echo "Created   : ${create_time} (${age_hours} hours old)"

		# -------------------------------------------------------------
		# RULE 1: If 24 hours or older -> Delete immediately
		# -------------------------------------------------------------
		if (( age_seconds >= CLEANUP_AGE_SECONDS )); then
			echo "Condition : 24 hours or older."
			if [ "$DRY_RUN" = "true" ]; then
				echo "[DRY-RUN] Would delete ${instance} at ${location}."
				continue
			else
				echo "Action    : DELETING ${instance} (abandoned orphan)..."
			fi

		# -------------------------------------------------------------
		# RULE 2: If less than 24 hours -> Check for active test builds
		# -------------------------------------------------------------
		else
			echo "Condition : Less than 24 hours old."
			echo "Checking for active Filestore Cloud Builds..."

			active_builds=$(gcloud builds list \
				--project "${PROJECT_ID}" \
				--filter="tags=m.filestore" \
				--format="value(id)" \
				--ongoing 2>/dev/null || true)

			if [[ -n "$active_builds" ]]; then
				echo "Result    : Active Filestore Cloud Build found ($active_builds)."
				echo "Decision  : KEEPING ${instance} (active test is using it)."
				KEPT_ACTIVE_INSTANCE=true
				continue
			else
				echo "Result    : No active Filestore Cloud Builds found."
				if [ "$DRY_RUN" = "true" ]; then
					echo "[DRY-RUN] Would delete ${instance} at ${location} (no active build)."
					continue
				else
					echo "Action    : DELETING ${instance} (leaked by finished/failed test)..."
				fi
			fi
		fi

		# -------------------------------------------------------------
		# EXECUTE DELETION (Only runs when DRY_RUN=false)
		# -------------------------------------------------------------
		echo "Disabling deletion protection for ${instance} at ${location}..."
		gcloud --project "${PROJECT_ID}" \
			filestore instances update "${instance}" \
			--location="${location}" \
			--no-deletion-protection \
			--quiet || true

		echo "Deleting ${instance} at ${location}..."
		gcloud --project "${PROJECT_ID}" \
			filestore instances delete \
			--force \
			--quiet \
			--location="${location}" \
			"${instance}"

		echo "Successfully deleted ${instance}."
	done <<<"$FILESTORE_INSTANCES"
else
	echo "No Filestore instances found in project."
fi

# =================================================================
# 2. SAFE NETWORK PEERING CLEANUP
# =================================================================
echo ""
echo "=========================================================="
echo "Checking network peerings..."
echo "=========================================================="

# Flatten nested peerings list so each peering outputs: <peering_name> <network_name>
peerings=$(gcloud compute networks peerings list \
	--project "${PROJECT_ID}" \
	--flatten="peerings[]" \
	--format="value(peerings.name,name)" 2>/dev/null || true)

found_filestore_peerings=false

if [[ -n "$peerings" ]]; then
	while read -r peering network; do
		[[ -z "$peering" ]] && continue

		# Only clean up Filestore peerings
		if [[ "$peering" =~ ^filestore-peer-[0-9]+$ ]]; then
			found_filestore_peerings=true
			echo ""
			echo "----------------------------------------------------"
			echo "Peering   : ${peering}"
			echo "Network   : ${network}"

			# Get creation time from Cloud Audit Logs
			creation_time=$(gcloud logging read \
				"protoPayload.methodName=~\"compute.networks.addPeering\" AND protoPayload.request.networkPeering.name=\"${peering}\"" \
				--project="${PROJECT_ID}" \
				--format="value(timestamp)" \
				--limit=1 2>/dev/null || true)

			# If creation time cannot be determined
			if [[ -z "$creation_time" ]]; then
				echo "Creation time for ${peering} could not be determined."
				if [ "$KEPT_ACTIVE_INSTANCE" = true ]; then
					echo "Decision  : KEEPING peering for safety (active instance detected)."
					continue
				fi
			fi

			creation_seconds=$(date -d "$creation_time" +%s 2>/dev/null || echo "")

			if [[ -n "$creation_seconds" ]]; then
				age_seconds=$((CURRENT_TIME - creation_seconds))
				age_hours=$((age_seconds / 3600))
				echo "Created   : ${creation_time} (${age_hours} hours old)"
			else
				age_seconds=-1
				echo "Created   : Unknown"
			fi

			# ---------------------------------------------------------
			# RULE 1: If 24 hours or older -> Delete immediately
			# ---------------------------------------------------------
			if (( age_seconds >= CLEANUP_AGE_SECONDS )); then
				echo "Condition : 24 hours or older."
				if [ "$DRY_RUN" = "true" ]; then
					echo "[DRY-RUN] Would delete dangling peering ${peering} from ${network}."
					continue
				else
					echo "Action    : DELETING dangling peering ${peering} from ${network}..."
				fi

			# ---------------------------------------------------------
			# RULE 2: If less than 24 hours -> Check active test builds
			# ---------------------------------------------------------
			else
				echo "Condition : Less than 24 hours old (or unknown age)."
				echo "Checking for active Filestore Cloud Builds..."

				active_builds=$(gcloud builds list \
					--project "${PROJECT_ID}" \
					--filter="tags=m.filestore" \
					--format="value(id)" \
					--ongoing 2>/dev/null || true)

				if [[ -n "$active_builds" ]] || [ "$KEPT_ACTIVE_INSTANCE" = true ]; then
					echo "Result    : Active Filestore Cloud Build or instance found."
					echo "Decision  : KEEPING peering ${peering} (active test is using it)."
					continue
				else
					echo "Result    : No active Filestore Cloud Builds found."
					if [ "$DRY_RUN" = "true" ]; then
						echo "[DRY-RUN] Would delete peering ${peering} from ${network} (no active build)."
						continue
					else
						echo "Action    : DELETING dangling peering ${peering} from ${network}..."
					fi
				fi
			fi

			# ---------------------------------------------------------
			# EXECUTE PEERING DELETION (Only runs when DRY_RUN=false)
			# ---------------------------------------------------------
			gcloud compute networks peerings delete \
				--project "${PROJECT_ID}" \
				--network "${network}" \
				"${peering}" \
				--quiet || true

			echo "Successfully deleted peering ${peering}."
		fi
	done <<<"$peerings"
fi

if [ "$found_filestore_peerings" = false ]; then
	echo "No dangling filestore-peer-* connections found in project."
fi

echo ""
echo "=========================================================="
echo "Filestore & Peering cleanup completed successfully."
echo "=========================================================="
exit 0
