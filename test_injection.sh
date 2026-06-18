#!/bin/bash
json='{"model":{"display_name":"M"},"context_window":{"used_percentage":"a[$(touch /tmp/hacked)]","context_window_size":1000000}}'
rm -f /tmp/hacked
echo "$json" | bash statusline.sh > /dev/null 2>&1
if [ -f /tmp/hacked ]; then
    echo "VULNERABLE!"
else
    echo "SAFE!"
fi
