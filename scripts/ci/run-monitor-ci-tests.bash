#!/bin/bash

set -eu -o pipefail

########################
# --- Script Summary ---
# This script is the junction between the CIs of the public UI and influxdb OSS repos and the monitor-ci CI (private).
# When the public CI is started, this script kicks off the private CI and waits for it to complete.
# This script uses the CircleCI APIs to make this magic happen.
#
# If the private CI fails, this script will collect the names and artifacts of the failed jobs and report them.
# This script should support multiple workflows if more are added, although it has not been tested.
# This script waits 50 minutes for the private CI to complete otherwise it fails.
#
# **For Running from the UI Repository:**
# If you want to retry failed jobs in the private CI, simply retry this job from the public CI.
#  - This script uses your commit SHA to search for a failed pipeline to retry before starting a new one.
#
# If you retry a failing job in the private CI and it passes, you can safely rerun this job in the public CI.
#  - This script uses your commit SHA to search for a passing pipeline before starting a new one.
#  - If you rerun the private CI and it passes, this script will find that pipeline and will not start a new one.
#  - In this situation the script will exit quickly with success.
#
# Required Env Vars for Running from the UI Repository:
# - SHA: the UI repo commit SHA we're running against
# - API_KEY: the CircleCI API access key
# - UI_BRANCH: the branch of the UI repo we're running against
# - MONITOR_CI_BRANCH: the branch of the monitor-ci repo to start a pipeline with (usually 'master')
# - PULL_REQUEST: the open pull request, if one exists (used for lighthouse)
#
# **For OSS-specific testing:**
# Since the OSS private CI is very simple, retrying a failing job in the private CI is not supported.
# OSS-specific testing can include evaluating changes on the OSS master branch against the latest UI acceptance image
# to make sure OSS API changes don't break the UI, and evaluating changes to an OSS binary with embedded UI assets with
# a specified UI commit that the UI is from (like a tagged release commit). This allows for the master branches of
# both the UI and influxdb OSS respositories to always stay compatible, and for OSS release builds to be e2e tested
# without needing to duplicate the entire private test infrastructure provided in monitor-ci.
#
# Required Env Vars for Testing Changes to OSS Master with the Latest Image Published from UI Master:
# - API_KEY: See "Required Env Vars for Running from the UI Repository".
# - OSS_SHA: the influxdb repo commit SHA we're running against
# - MONITOR_CI_BRANCH: the branch of the monitor-ci repo to start a pipeline with (usually 'master')
#
# Required Env Vars for Testing Changes to an OSS Image with Embedded UI with e2e tests from a Specific UI Commit:
# - API_KEY: See "Required Env Vars for Running from the UI Repository".
# - SHA: the UI repo commit SHA we want to build and run e2e tests from
# - UI_BRANCH: the branch of the UI repo we're running against
# - OSS_SHA: the influxdb repo commit SHA we're running against
# - MONITOR_CI_BRANCH: the branch of the monitor-ci repo to start a pipeline with (usually 'master')

########################

# starts a new monitor-ci pipeline with provided parameters
startNewPipeline() {
	pipelineStartMsg=$1
	reqData=$2

	printf "\n${pipelineStartMsg}\n"
	pipeline=$(curl -s --fail --request POST \
		--url https://circleci.com/api/v2/project/gh/influxdata/monitor-ci/pipeline \
		--header "Circle-Token: ${API_KEY}" \
		--header 'content-type: application/json' \
		--header 'Accept: application/json'    \
		--data "${reqData}")

	if [ $? != 0 ]; then
		echo "failed to start the monitor-ci pipeline, quitting"
		exit 1
	fi

	# set variables to identify pipeline to watch
	pipeline_id=$(echo ${pipeline} | jq  -r '.id')
	pipeline_number=$(echo ${pipeline} | jq -r '.number')

	printf "\nwaiting for monitor-ci pipeline to begin...\n"
	sleep 1m
	printf "\nmonitor-ci pipeline has begun. Running pipeline number ${pipeline_number} with id ${pipeline_id}\n"
}

# retries all failed jobs from a previously failed monitor-ci pipeline
retryFailedPipeline() {
	failed_pipeline_workflow_id=$1
	failed_pipeline_id=$2
	failed_pipeline_number=$3

	pipeline=$(curl -s --fail --request POST \
		--url https://circleci.com/api/v2/workflow/${failed_pipeline_workflow_id}/rerun \
		--header "Circle-Token: ${API_KEY}" \
		--header 'content-type: application/json' \
		--header 'Accept: application/json'    \
		--data "{ \"from_failed\": true }")

	if [ $? != 0 ]; then
		echo "failed to re-run the monitor-ci pipeline, quitting"
		exit 1
	fi

	# set variables to identify pipeline to watch
	pipeline_id=$failed_pipeline_id
	pipeline_number=$failed_pipeline_number

	printf "\nwaiting for monitor-ci pipeline to begin the re-run...\n"
	sleep 1m
	printf "\nmonitor-ci pipeline re-run has begun. Running pipeline number ${pipeline_number} with id ${pipeline_id}\n"
}

# make dir for artifacts
mkdir -p monitor-ci/test-artifacts/results/{build-oss-image,oss-e2e,build-image,cloud-e2e,cloud-e2e-firefox,cloud-e2e-k8s-idpe,cloud-lighthouse,smoke,build-prod-image,deploy}/{shared,oss,cloud}

# get monitor-ci pipelines we've already run on this SHA
found_passing_pipeline=0
found_failed_pipeline=0

# If OSS_SHA is not set, run the standard UI pipeline with the latest OSS backend docker image.
if [[ -z "${OSS_SHA:-}" ]]; then
  required_workflows=( "build" )

	all_pipelines=$(curl -s --request GET \
			--url "https://circleci.com/api/v2/project/gh/influxdata/monitor-ci/pipeline" \
			--header "Circle-Token: ${API_KEY}" \
			--header 'content-type: application/json' \
			--header 'Accept: application/json')

	# check the status of the workflows for each of these pipelines
	all_pipelines_ids=( $(echo ${all_pipelines} | jq -r '.items | .[].id') )
	for pipeline_id in "${all_pipelines_ids[@]}"; do

		config=$(curl -s --request GET \
			--url "https://circleci.com/api/v2/pipeline/${pipeline_id}/config" \
			--header "Circle-Token: ${API_KEY}" \
			--header 'content-type: application/json' \
			--header 'Accept: application/json')

		# finds the UI SHA parameter used in this pipeline by hunting for the line "export UI_SHA="
		pipeline_ui_sha=$(echo ${config} | jq '.compiled' | grep -o 'export UI_SHA=[^\]*' | grep -v 'export UI_SHA=${LATEST_SHA}' | head -1 | sed 's/=/\n/g' | tail -1 || true)

		if [[ "${SHA}" == "${pipeline_ui_sha}" ]]; then
			# check if this pipeline's 'build' workflow is passing
			workflows=$(curl -s --request GET \
				--url "https://circleci.com/api/v2/pipeline/${pipeline_id}/workflow" \
				--header "Circle-Token: ${API_KEY}" \
				--header 'content-type: application/json' \
				--header 'Accept: application/json')

			number_build_success_workflows=$(echo ${workflows} | jq '.items | map(select(.name == "build" and .status == "success")) | length')
			if [ $number_build_success_workflows -gt 0 ]; then
				# we've found a successful run
				found_passing_pipeline=1
				break
			fi

			number_build_failed_workflows=$(echo ${workflows} | jq '.items | map(select(.name == "build" and .status == "failed")) | length')
			if [ $number_build_failed_workflows -gt 0 ]; then
				# there's a failed run, let's retry it
				found_failed_pipeline=1
				failed_pipeline_workflow_id=$(echo ${workflows} | jq -r '.items | .[0] | .id')
				failed_pipeline_id=$pipeline_id
				failed_pipeline_number=$(echo ${all_pipelines} | jq -r --arg pipeline_id "${pipeline_id}" '.items | map(select(.id == $pipeline_id)) | .[0] | .number')
				break
			fi
		fi
	done

	# terminate early if we found a passing pipeline for this SHA
	if [ $found_passing_pipeline -eq 1 ]; then
		printf "\nSUCCESS: Found a passing monitor-ci pipeline for this SHA, will not re-run these tests\n"
		exit 0
	elif [ $found_failed_pipeline -eq 1 ]; then
		printf "\nfound a failed monitor-ci pipeline for this SHA, will retry the failed jobs\n"
	else
		printf "\nno passing monitor-ci pipelines found for this SHA, starting a new one\n"
	fi

	# set the parameters for starting the monitor-ci pipeline from the UI repo
	DEPLOY_PROD=false
	if [[ "${UI_BRANCH}" == "master" ]]; then
		# In order to deploy to prod:
		# - UI_BRANCH must be 'master'
		# - MONITOR_CI_BRANCH must be 'master'
		# - DEPLOY_PROD must be 'true'
		# - UI_GITHUB_ORG must be 'influxdata'
		# UI_BRANCH, DEPLOY_PROD are both neccesary to ensure that UI_BRANCH parameter's default in the monitor-ci pipeline doesn't deploy us to production unless started by this script.
		DEPLOY_PROD=true
	fi
	if [ -n "${PULL_REQUEST}" ]; then
		# if running from pull request, use github api to get source org and branch.
		# this is needed to support forks of the UI repo.
		pr=$(echo ${PULL_REQUEST} | grep -oE "[^/]+$")
		github=$(curl -s --fail --request GET \
			--url https://api.github.com/repos/influxdata/ui/pulls/${pr})
		UI_BRANCH=$(echo ${github} | jq -r '.head.ref')
		UI_GITHUB_ORG=$(echo ${github} | jq -r '.head.repo.owner.login')
	fi

	pipelineStartMsg="starting monitor-ci pipeline targeting monitor-ci branch ${MONITOR_CI_BRANCH}, UI branch ${UI_BRANCH} and using UI SHA ${SHA}"
	reqData="{\"branch\":\"${MONITOR_CI_BRANCH}\", \"parameters\":{ \"ui-sha\":\"${SHA}\", \"ui-github-org\":\"${UI_GITHUB_ORG:-influxdata}\", \"ui-branch\":\"${UI_BRANCH}\", \"ui-pull-request\":\"${PULL_REQUEST}\", \"ui-pr-author\":\"${CIRCLE_USERNAME}\", \"deploy-prod\":${DEPLOY_PROD}}}"
else
  # if OSS_SHA parameter is set, run a minimal pipeline for OSS-specific testing.
	if [[ -z "${SHA:-}" ]]; then
    # no UI sha means to run the tests through the latest UI docker image with the OSS API backend based on the provided OSS commit SHA
	  required_workflows=( "build-oss" )
	  pipelineStartMsg="starting monitor-ci pipeline targeting monitor-ci branch ${MONITOR_CI_BRANCH} using OSS SHA ${OSS_SHA}"
    reqData="{\"branch\":\"${MONITOR_CI_BRANCH}\", \"parameters\":{ \"oss-sha\":\"${OSS_SHA}\" }}"
	else
	  # if both a UI and OSS SHA are provided, run with the OSS backend with an embedded UI, and run the tests on it built from the commit referenced by the UI SHA..
    required_workflows=( "build-oss-embedded" )
    pipelineStartMsg="starting monitor-ci pipeline targeting monitor-ci branch ${MONITOR_CI_BRANCH} using OSS SHA ${OSS_SHA} and UI SHA ${SHA}"
    reqData="{\"branch\":\"${MONITOR_CI_BRANCH}\", \"parameters\":{ \"ui-sha\":\"${SHA}\", \"oss-sha\":\"${OSS_SHA}\", \"ui-branch\":\"${UI_BRANCH}\" }}"
  fi
fi

# start a new pipeline if we didn't find an existing one to retry
if [ $found_failed_pipeline -eq 0 ]; then
	startNewPipeline "${pipelineStartMsg}" "${reqData}"
else
	retryFailedPipeline ${failed_pipeline_workflow_id} ${failed_pipeline_id} ${failed_pipeline_number}
fi

# poll the status of the monitor-ci pipeline
is_failure=0
attempts=0
max_attempts=30 # minutes
while [ $attempts -le $max_attempts ];
do

	workflows=$(curl -s --request GET \
		--url "https://circleci.com/api/v2/pipeline/${pipeline_id}/workflow" \
		--header "Circle-Token: ${API_KEY}" \
		--header 'content-type: application/json' \
		--header 'Accept: application/json')

	number_running_workflows=$(echo ${workflows} | jq  -r '.items | map(select(.status == "running" or .status == "failing")) | length')

	# when the pipeline has finished
	if [ ${number_running_workflows} -eq 0 ]; then
		# report failed jobs per required workflow
		for required_workflow_name in "${required_workflows[@]}"; do
			workflow_id=$(echo ${workflows} | jq -r --arg name "${required_workflow_name}" '.items | map(select(.name == $name and .status == "success")) | .[].id')

			if [ -n "${workflow_id}" ]; then
				printf "\nSUCCESS: monitor-ci workflow with id ${workflow_id} passed: https://app.circleci.com/pipelines/github/influxdata/monitor-ci/${pipeline_number}/workflows/${workflow_id} \n"
			else
				# set job failure
				is_failure=1

				# get the workflow_id of this failed required workflow (if there are multiple, get the most recent one)
				workflow_id=$(echo ${workflows} | jq -r --arg name "${required_workflow_name}" '.items |= sort_by(.created_at) | .items | map(select(.name == $name and .status == "failed")) | .[-1].id')

				# get the jobs that failed for this workflow
				jobs=$(curl -s --request GET \
					--url "https://circleci.com/api/v2/workflow/${workflow_id}/job" \
					--header "Circle-Token: ${API_KEY}" \
					--header 'content-type: application/json' \
					--header 'Accept: application/json')

				# print the names of the failed jobs
				printf "\nFailed jobs:\n"
				failed_jobs=$(echo ${jobs} | jq '.items | map(select(.status == "failed"))')
				failed_jobs_names=( $(echo ${failed_jobs} | jq -r '.[].name') )
				for name in "${failed_jobs_names[@]}"; do
					printf " - ${name}\n"
				done

				# get the artifacts for each failed job
				printf "\nArtifacts from failed jobs:\n"
				for name in "${failed_jobs_names[@]}"; do
					printf "\n===== ${name} =====\n"
					job_number=$(echo ${failed_jobs} | jq -r --arg name "${name}" 'map(select(.name == $name)) | .[].job_number')
					artifacts=$(curl -s --request GET \
						--url "https://circleci.com/api/v1.1/project/github/influxdata/monitor-ci/${job_number}/artifacts" \
						--header "Circle-Token: ${API_KEY}" \
						--header 'content-type: application/json' \
						--header 'Accept: application/json')

					artifacts_length=$(echo ${artifacts} | jq -r 'length')
					if [ ${artifacts_length} -eq 0 ]; then
						printf "\n No artifacts for this failed job.\n"
					else
						artifacts_urls=( $(echo ${artifacts} | jq -r '.[].url') )
						# download each artifact
						for url in "${artifacts_urls[@]}"; do
							path=$(echo ${artifacts} | jq --arg url "${url}" 'map(select(.url == $url)) | .[].pretty_path')

							# download artifact
							filename=$(basename "${path}")
							filename="${filename::-1}" # removes extra " from end
							# put shared artifacts in the shared folder
							if [[ "${path}" == *"shared"* ]] ; then
								subdirectory="shared"
							else
								if [[ "${path}" == *"cloud"* ]] ; then
									subdirectory="cloud"
								else
									subdirectory="oss"
								fi
							fi
							safeName="${name//\//-}"
							if [[ "${safeName}" == *"remocal"* ]]; then
								# put all remocal artifacts in the same parent directory
								safeName="remocal/${safeName}"
							fi
							mkdir -p "monitor-ci/test-artifacts/results/${safeName}/${subdirectory}"
							output="monitor-ci/test-artifacts/results/${safeName}/${subdirectory}/${filename}"
							curl -L -s --request GET \
								--output "${output}" \
								--url "${url}" \
								--header "Circle-Token: ${API_KEY}"
						done
						printf "\n ${artifacts_length} artifacts successfully downloaded for this failed job.\n"
					fi
				done

				printf "\n\nFAILURE: monitor-ci workflow with id ${workflow_id} failed.\n"
				printf "\n********************************************************\n"
				printf "monitor-ci pipeline link: \nhttps://app.circleci.com/pipelines/github/influxdata/monitor-ci/${pipeline_number}/workflows/${workflow_id}\n"
				printf "\n********************************************************\n"
			fi
		done

		exit $is_failure
	fi

	# sleep 1 minute and poll the status again
	attempts=$(($attempts+1))
	remaining_attempts=$(($max_attempts-$attempts))
	printf "\nmonitor-ci pipeline ${pipeline_number} isn't finished yet, waiting another minute... ($remaining_attempts minutes left)\n"
	sleep 1m

done

printf "\nmonitor-ci pipeline did not finish in time, quitting\n"
exit 1
