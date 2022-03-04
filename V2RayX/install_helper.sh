#!/bin/sh

#  install_helper.sh
#  V2RayX
#
#  Copyright © 2016年 Cenmrev. All rights reserved.

cd `dirname "${BASH_SOURCE[0]}"`
sudo mkdir -p "/Library/Application Support/V2RayXS/"
sudo cp v2rayx_sysconf "/Library/Application Support/V2RayXS/"
sudo chown root:admin "/Library/Application Support/V2RayXS/v2rayx_sysconf"
sudo chmod +s "/Library/Application Support/V2RayXS/v2rayx_sysconf"

echo done
