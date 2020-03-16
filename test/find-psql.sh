#!/bin/bash

for p in $(echo $PATH | sed 's/:/ /g'); do
    echo "Check $p"
    if [ -d $p ]; then
	echo "$p exists as a directory"
	if [ -x $p/psql ]; then
	    echo "$p/psql is executable"
	fi
    fi
done

which psql
