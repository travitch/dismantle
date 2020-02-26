#!/usr/bin/env bash

set -euo pipefail

ISA=ISA_v85A_AArch32_xml_00bet9
ISA_mini=ISA_uboot_req
cd `dirname "$BASH_SOURCE"`
cd ..

cd ./dismantle-arm-xml/data
git checkout $ISA
git checkout $ISA_mini

rm -rf $ISA-all
mv $ISA $ISA-all
mv $ISA_mini $ISA

cd ../test/
git checkout ./bin
rm -rf ./bin-all
mv ./bin ./bin-all
mkdir ./bin
mv ./bin-all/u-boot* ./bin
