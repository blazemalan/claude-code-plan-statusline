#!/bin/bash
json='{"model":{"display_name":"M"},"rate_limits":{"five_hour":{"used_percentage":"0[$(touch /tmp/hacked_tier)]","resets_at":1746234000}}}'
rm -f /tmp/hacked_tier
echo "$json" | bash statusline.sh > /dev/null 2>&1
if [ -f /tmp/hacked_tier ]; then
    echo "VULNERABLE!"
else
    echo "SAFE!"
fi
