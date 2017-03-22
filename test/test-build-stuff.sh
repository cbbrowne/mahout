#!/bin/bash

# Let's set up a database and put some schema into it as a Base Schema
PGCMPHOME=${HOME}/PostgreSQL/pgcmp
DBCLUSTER=postgresql://postgres@localhost:7099
MAHOUT=${PWD}/../mahout
PROJECTNAME=mhtest
TARGETDIR=install-target
TARGETMHDIR=install-target/${PROJECTNAME}

clusterdb=${DBCLUSTER}/postgres
devdb=devdb
devuri=${DBCLUSTER}/${devdb}
comparisondb=comparisondb
compuri=${DBCLUSTER}/${comparisondb}
installdb=installdb
installuri=${DBCLUSTER}/${installdb}

function glog () {
    local level=$1
    local notice=$2 
    logger -i -p "${level}" -t "test-build-stuff.sh" "${notice}"
    case ${level} in
	user.debug)
	    DEBUGS=$((${DEBUGS} + 1))
  	    ;;
	*)
	    echo "${level} mahout ${notice}"
	    ;;
    esac
    if [ -d ${MAHOUTLOG} ]; then
	when=`date --rfc-3339=seconds`
	echo "${when} ${level} mahout ${notice}" >> ${MAHOUTLOG}/mahout.log
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
for i in ${devdb} ${comparisondb} ${installdb}; do
    glog user.notice "Drop and recreate database ${i} on cluster ${clusterdb}"
    psql -d ${clusterdb} \
	 -c "drop database if exists ${i};"
    psql -d ${clusterdb} \
         -c "create database ${i};"
done

glog user.notice "Set up a simple schema"

psql -d ${devdb} -c "
  create table t1 (id serial primary key, name text not null unique, created_on timestamptz default now());
  create schema subschema;
  create table subschema.t2 (id serial primary key, name text not null unique, created_on timestamptz default now());
"

glog user.notice "Do mahout init to capture that base schema"

rm -rf ./${PROJECTNAME}
MAHOUTSCHEMA=MaHoutSchema PGCMPHOME=${PGCMPHOME} MAINDATABASE=${devuri} SUPERUSERACCESS=${clusterdb} COMPARISONDATABASE=${compuri} ${MAHOUT} init ${PROJECTNAME}

glog user.notice "Do mahout capture; expect no change"
# Run mahout capture, without any change
(cd ${PROJECTNAME}; ${MAHOUT} capture)

glog user.notice "Set up filesystem to use the captured mahout config for a fresh install"
# Set up target directory for sample installation
rm -rf ${TARGETDIR}
mkdir ${TARGETDIR}
cp -r ${PROJECTNAME} ${TARGETDIR}

function fix_install_uri () {
# Drop alternate configuration into installation Mahout config
    glog user.notice "fix up install instance to use ${installuri} rather than the URI provided in the build"
    egrep -v MAINDATABASE ${TARGETMHDIR}/mahout.conf > ${TARGETMHDIR}/mahout.conf.keep
    echo "
MAINDATABASE=${installuri}
" >> ${TARGETMHDIR}/mahout.conf.keep
    cp ${TARGETMHDIR}/mahout.conf.keep ${TARGETMHDIR}/mahout.conf
}
fix_install_uri

glog user.notice "Install basic schema using mahout"
(cd ${TARGETMHDIR}; ${MAHOUT} install)

glog user.notice "Prepare upgrade for v1.1"
# Create a couple of upgrades
echo "

version 1.1
requires Base
psql 1.1/stuff.sql

" >> ${PROJECTNAME}/mahout.control

mkdir ${PROJECTNAME}/1.1
echo "
   alter table t1 add column deleted_on timestamptz;
" > ${PROJECTNAME}/1.1/stuff.sql

glog user.notice "mahout capture on v1.1"
(cd ${PROJECTNAME}; ${MAHOUT} capture)

glog user.notice "do upgrade of the install instance to run v1.1"
cp -r ${PROJECTNAME} ${TARGETDIR}
fix_install_uri
# And try to install the upgrade
(cd ${TARGETMHDIR}; ${MAHOUT} upgrade)

echo "

version 1.2
requires 1.1
psql 1.2/stuff.sql

" >> ${PROJECTNAME}/mahout.control
mkdir ${PROJECTNAME}/1.2
echo "
   create table t3 (
     id serial primary key,
     name text not null unique,
     created_on timestamptz not null default now());

" > ${PROJECTNAME}/1.2/stuff.sql

glog user.notice "Run mahout capture to put that into the build"

glog user.notice "mahout capture on v1.2"
(cd ${PROJECTNAME}; ${MAHOUT} capture)

glog user.notice "do upgrade of the install instance to run v1.2"
cp -r ${PROJECTNAME} ${TARGETDIR}
fix_install_uri
(cd ${TARGETMHDIR}; ${MAHOUT} upgrade)


echo "

version 1.3
requires 1.2
psql 1.3/stuff.sql

" >> ${PROJECTNAME}/mahout.control

mkdir ${PROJECTNAME}/1.3

echo "
   alter table t3 add column deleted_on timestamptz;
   create index t3_deleted on t3(deleted_on) where (deleted_on is not null);

" > ${PROJECTNAME}/1.3/stuff.sql

glog user.notice "mahout capture on v1.3"
(cd ${PROJECTNAME}; ${MAHOUT} capture)

echo "

version 1.4
requires 1.3
psql 1.4/stuff.sql

" >> ${PROJECTNAME}/mahout.control

mkdir ${PROJECTNAME}/1.4

echo "
   alter table t3 drop column deleted_on;
   alter table t3 add column updated_on timestamptz default now();
" > ${PROJECTNAME}/1.4/stuff.sql

glog user.notice "mahout capture on v1.4"
(cd ${PROJECTNAME}; ${MAHOUT} capture)

glog user.notice "do upgrade of the install instance to run v1.3, v1.4"
cp -r ${PROJECTNAME} ${TARGETDIR}
fix_install_uri
(cd ${TARGETMHDIR}; ${MAHOUT} upgrade)
