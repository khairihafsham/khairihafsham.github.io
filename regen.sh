#!/bin/bash

set -x

contentpath="$1/ignore"
content="$contentpath/index.md"
target="$1/content.md"

cp $content $target

ls $contentpath | ggrep -v '.md$' | xargs -I {} cp $contentpath/{} $1/{}
