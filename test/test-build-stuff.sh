#!/bin/bash

# Let's set up a database and put some schema into it as a Base Schema
PGCMPHOME=${HOME}/PostgreSQL/pgcmp
DBCLUSTER=postgresql://postgres@localhost:7099
MAHOUT=${PWD}/../mahout

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

PROJECTNAME=mhtest

psql -d ${devdb} -c "
  create table t1 (id serial primary key, name text not null unique, created_on timestamptz default now());
  create schema subschema;
  create table subschema.t2 (id serial primary key, name text not null unique, created_on timestamptz default now());
"

rm -rf ./${PROJECTNAME}
MAHOUTSCHEMA=MaHoutSchema PGCMPHOME=${PGCMPHOME} MAINDATABASE=${devuri} SUPERUSERACCESS=${CLUSTERDB} COMPARISONDATABASE=${comparisondb} ${MAHOUT} init ${PROJECTNAME}

cd ${PROJECTNAME}
${MAHOUT} capture
