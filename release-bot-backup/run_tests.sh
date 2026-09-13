#!/bin/bash
PR_NUMBER=$1

if [ -z "$PR_NUMBER" ]; then
    echo "Usage: $0 <PR_NUMBER>"
    exit 1
fi

echo "Running tests using babysit for PR $PR_NUMBER..."
python3 tools/cloud-build/babysit/run --project "hpc-toolkit-dev" --pr "$PR_NUMBER" --all --concurrency 4 --retries 1
