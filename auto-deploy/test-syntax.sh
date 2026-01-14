#!/bin/bash

# Test syntax of all scripts
# Run this to validate that all bash scripts have valid syntax

echo "Testing syntax of all scripts..."
echo ""

errors=0

for script in deploy.sh lib/*.sh; do
    echo -n "Checking $script... "
    if bash -n "$script" 2>/dev/null; then
        echo "✅ OK"
    else
        echo "❌ SYNTAX ERROR"
        bash -n "$script"
        ((errors++))
    fi
done

echo ""
if [ $errors -eq 0 ]; then
    echo "✅ All scripts have valid syntax!"
    exit 0
else
    echo "❌ Found $errors script(s) with syntax errors"
    exit 1
fi
