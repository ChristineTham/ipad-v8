#!/bin/sh
# mkdir -p, which V8's mkdir does not have: it makes exactly one level and
# fails on a missing parent.  Used by stage.sh when an incremental copy has to
# create a directory the previous run never needed.
p=""
IFS=/
for c in $1
do
	if test -z "$c"
	then
		p=""
		continue
	fi
	p="$p/$c"
	test -d "$p" || mkdir "$p" 2>/dev/null
done
exit 0
