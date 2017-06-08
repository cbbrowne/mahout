#!/bin/bash
set -e -u

# Let's set up a database and put some schema into it as a Base Schema
PGCMPHOME=${PGCMPHOME:-${HOME}/PostgreSQL/pgcmp}
DBCLUSTER=${DBCLUSTER:-"postgresql://postgres@localhost:7099"}
MAHOUTHOME=${MAHOUTHOME:-${HOME}/PostgreSQL/mahout}
TARGETDIR=${TARGETDIR:-"install-target"}
MAHOUTLOGDIR=${MAHOUTLOG:-"/tmp/mahout-tests"}

PROJECTNAME=mhtest
TARGETMHDIR=install-target/${PROJECTNAME}
MAHOUT=${MAHOUTHOME}/mahout

if [ -d ${MAHOUTLOGDIR} ]; then
    MAHOUTLOG=${MAHOUTLOGDIR}/mahout.log
else
    mkdir -p ${MAHOUTLOGDIR}
    MAHOUTLOG=${MAHOUTLOGDIR}/mahout.log
    echo "initialize mahout.log" > ${MAHOUTLOG}
fi

if [ -d ${PROJECTNAME} ]; then
    echo "Project directory ${PROJECTNAME} already there"
else
    mkdir -p ${PROJECTNAME}
fi

clusterdb=${DBCLUSTER}/postgres
devdb=devdb
devuri=${DBCLUSTER}/${devdb}
comparisondb=comparisondb
compuri=${DBCLUSTER}/${comparisondb}
installdb=installdb
installuri=${DBCLUSTER}/${installdb}
proddb=proddb
produri=${DBCLUSTER}/${proddb}

NOTICES=0
WARNINGS=0
PROBLEMS=0

function glog () {
    local level=$1
    local notice=$2 
    logger -i -p "${level}" -t "test-build-stuff.sh" "${notice}"
    case ${level} in
	user.debug)
	    DEBUGS=$((${DEBUGS} + 1))
  	    ;;
	*)
	    echo "${level} test-build-stuff.sh ${notice}"
	    ;;
    esac
    if [ -f ${MAHOUTLOG} ]; then
	when=`date --rfc-3339=seconds`
	echo "${when} ${level} mahout ${notice}" >> ${MAHOUTLOG}
    fi
    case ${level} in
	user.notice)
	    NOTICES=$((${NOTICES} + 1))
	    ;;
	user.warning)
	    WARNINGS=$((${WARNINGS} + 1))
	    ;;
	user.error)
	    PROBLEMS=$((${PROBLEMS} + 1))
	    ;;
    esac	    
}


# Drop databases and then create them
for i in ${devdb} ${comparisondb} ${installdb} ${proddb}; do
    glog user.notice "Drop and recreate database ${i} on cluster ${clusterdb}"
    psql -d ${clusterdb} \
	 -c "drop database if exists ${i};"
    psql -d ${clusterdb} \
         -c "create database ${i};"
done

glog user.notice "Use mahout to install schema against all three nodes"

