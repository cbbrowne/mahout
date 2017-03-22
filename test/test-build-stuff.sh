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

# Drop databases and then create them
for i in ${devdb} ${comparisondb} ${installdb}; do
    psql -d ${clusterdb} \
	 -c "drop database if exists ${i};"
    psql -d ${clusterdb} \
         -c "create database ${i};"
done

psql -d ${devdb} -c "
  create table t1 (id serial primary key, name text not null unique, created_on timestamptz default now());
  create schema subschema;
  create table subschema.t2 (id serial primary key, name text not null unique, created_on timestamptz default now());
"

rm -rf ./${PROJECTNAME}
MAHOUTSCHEMA=MaHoutSchema PGCMPHOME=${PGCMPHOME} MAINDATABASE=${devuri} SUPERUSERACCESS=${clusterdb} COMPARISONDATABASE=${compuri} ${MAHOUT} init ${PROJECTNAME}

# Run mahout capture, without any change
(cd ${PROJECTNAME}; ${MAHOUT} capture)

# Set up target directory for sample installation
rm -rf ${TARGETDIR}
mkdir ${TARGETDIR}
cp -r ${PROJECTNAME} ${TARGETDIR}

# Drop alternate configuration into installation Mahout config
egrep -v MAINDATABASE ${TARGETMHDIR}/mahout.conf > ${TARGETMHDIR}/mahout.conf.keep
echo "
MAINDATABASE=${installuri}
" >> ${TARGETMHDIR}/mahout.conf.keep
mv ${TARGETMHDIR}/mahout.conf.keep ${TARGETMHDIR}/mahout.conf

# Create a couple of upgrades
echo "
version 1.1
requires Base
psql 1.1/stuff.sql

version 1.2
requires 1.1
psql 1.2/stuff.sql

" >> ${PROJECTNAME}/mahout.control

mkdir ${PROJECTNAME}/1.1
echo "
   alter table t1 add column deleted_on timestamptz;
" > ${PROJECTNAME}/1.1/stuff.sql

# mahout capture
(cd ${PROJECTNAME}; ${MAHOUT} capture)
# copy over to target installation
cp -r ${PROJECTNAME} ${TARGETDIR}
# And try to install the upgrade
(cd ${TARGETMHDIR}; ${MAHOUT} upgrade)

mkdir ${PROJECTNAME}/1.2
echo "
   create table t3 (
     id serial primary key,
     name text not null unique,
     created_on timestamptz not null default now());

" > ${PROJECTNAME}/1.2/stuff.sql

# Another upgrade to capture
(cd ${PROJECTNAME}; ${MAHOUT} capture)
# and to copy to target
cp -r ${PROJECTNAME} ${TARGETDIR}
# and to try to upgrade   
(cd ${TARGETMHDIR}; ${MAHOUT} upgrade)
