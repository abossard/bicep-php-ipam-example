#!/bin/bash

variable="feature/env"

# 1. Check if variable starts with "feature/"
if [[ $variable == feature/* ]]; then
    echo "The variable starts with 'feature/'."
    
    # 2. Extract part after "feature/"
    extracted="${variable#feature/}"

    # 3. Replace all slashes with underscores
    replaced="${extracted//\//_}"

    echo "Extracted part: $extracted"
    echo "Replaced slashes with underscores: $replaced"

else
    echo "The variable does not start with 'feature/'."
fi
