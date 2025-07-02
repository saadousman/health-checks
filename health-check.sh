#!/bin/bash
set -e
set -o pipefail

# Unified Kubernetes readiness checker for Deployments and StatefulSets
# Usage: ./script.sh check_readiness <kind> <name> <namespace> [timeout]
# Example: ./script.sh check_readiness deployment my-deploy default 300

check_resource_readiness() {
    sleep 10s  # Initial delay to allow resources to start

    local kind="$1"         # Resource kind: deployment or statefulset
    local name="$2"         # Resource name
    local namespace="$3"    # Kubernetes namespace
    local timeout_sec="${4:-500}"  # Timeout in seconds (default: 500)

    # Validate input arguments
    if [ -z "$kind" ] || [ -z "$name" ] || [ -z "$namespace" ]; then
        echo "Error: Missing arguments. Usage: <kind> <name> <namespace> [timeout]"
        return 1
    fi

    # Validate namespace existence
    if ! kubectl get ns "$namespace" >/dev/null 2>&1; then
        echo "Error: Namespace $namespace does not exist."
        return 1
    fi

    # Validate resource existence
    if ! kubectl get "$kind" "$name" -n "$namespace" >/dev/null 2>&1; then
        echo "Error: $kind $name not found in namespace $namespace."
        return 1
    fi

    echo "Checking readiness for $kind: $name in namespace: $namespace"
    local start_time=$(date +%s)

    while true; do
        local elapsed_time=$(( $(date +%s) - start_time ))

        # Exit with failure if timeout is reached
        if [ "$elapsed_time" -ge "$timeout_sec" ]; then
            echo "Timeout reached after $timeout_sec seconds. Exiting with failure."
            return 1
        fi

        # Get number of ready and desired replicas
        local ready_replicas=$(kubectl get "$kind" "$name" -n "$namespace" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
        local desired_replicas=$(kubectl get "$kind" "$name" -n "$namespace" -o jsonpath='{.status.replicas}' 2>/dev/null)

        ready_replicas=${ready_replicas:-0}
        desired_replicas=${desired_replicas:-0}

        # Fail if no desired replicas
        if [ "$desired_replicas" -eq 0 ]; then
            echo "Warning: $kind has 0 desired replicas."
            return 1
        fi

        # Extract the actual label selector from the resource spec
        local label_selector=$(kubectl get "$kind" "$name" -n "$namespace" -o jsonpath='{.spec.selector.matchLabels}' | jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")')

        # Get number of not ready pods
        local not_ready=$(kubectl get pods -n "$namespace" -l "$label_selector" -o json | jq '[.items[] | select(.status.conditions[]? | select(.type=="Ready" and .status!="True"))] | length')

        # Detect known container failure reasons
        local crash_loop=$(kubectl get pods -n "$namespace" -l "$label_selector" -o json | jq '[.items[] | .status.containerStatuses[]? | select(.state.waiting.reason == "CrashLoopBackOff" or .state.waiting.reason == "ImagePullBackOff" or .state.waiting.reason == "ErrImagePull" or .state.waiting.reason == "RunContainerError")] | length')

        # Count pods with high cumulative restart counts
        local high_restart=$(kubectl get pods -n "$namespace" -l "$label_selector" -o json | jq '[.items[] | select((.status.containerStatuses | map(.restartCount // 0) | add) > 3)] | length')

        # Exit immediately on critical container failures
        if [ "$crash_loop" -gt 0 ] || [ "$high_restart" -gt 0 ]; then
            echo "Detected pod failure conditions (CrashLoop, HighRestarts). Exiting with failure."
            return 1
        fi

        # If all replicas are ready and no pods are unready, declare success
        if [ "$ready_replicas" -eq "$desired_replicas" ] && [ "$not_ready" -eq 0 ]; then
            echo "$kind '$name' is ready. Ready replicas: $ready_replicas."
            return 0
        fi

        # Show progress
        echo "Waiting... Ready: $ready_replicas, Desired: $desired_replicas, Not Ready Pods: $not_ready, CrashLoopBackOff: $crash_loop, HighRestarts: $high_restart"
        sleep 5
    done
}

# Entry point
if [ "$1" = "check_readiness" ]; then
    check_resource_readiness "$2" "$3" "$4" "$5"
fi
