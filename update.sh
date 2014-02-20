#!/bin/bash -x
if [ -n "$(git status --porcelain)" ]; then 
  echo "Looks like there are local changes. Bail."
  exit 1
fi

if [ ! -d "../bleeding_edge" ] ; then
  echo 'Need to `git clone https://github.com/tapted/bleeding_edge.git` into ../bleeding_edge. Bail.'
  exit 1
fi

echo 'Note that this does not `git pull` in bleeding_edge or check that it is currently on master.'

(cd ../bleeding_edge && git archive HEAD:dart/sdk/lib/_internal/pub) | tar x
git add --all
git diff --stat
echo 'Now `git commit`'
