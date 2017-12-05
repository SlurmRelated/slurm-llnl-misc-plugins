#!/bin/bash
# -*- coding: utf-8 -*-
##############################################################################
#  Copyright (C) 2015-2017 EDF SA                                            #
#                                                                            #
#  Author: CCN HPC <dsp
#                                                                            #
#  This file is part of slurm-llnl-misc-plugins.                             #
#                                                                            #
#  This software is governed by the CeCILL-C license under French law and    #
#  abiding by the rules of distribution of free software. You can use,       #
#  modify and/ or redistribute the software under the terms of the CeCILL-C  #
#  license as circulated by CEA, CNRS and INRIA at the following URL         #
#  "http://www.cecill.info".                                                 #
#                                                                            #
#  As a counterpart to the access to the source code and rights to copy,     #
#  modify and redistribute granted by the license, users are provided only   #
#  with a limited warranty and the software's author, the holder of the      #
#  economic rights, and the successive licensors have only limited           #
#  liability.                                                                #
#                                                                            #
#  In this respect, the user's attention is drawn to the risks associated    #
#  with loading, using, modifying and/or developing or reproducing the       #
#  software by the user in light of its specific status of free software,    #
#  that may mean that it is complicated to manipulate, and that also         #
#  therefore means that it is reserved for developers and experienced        #
#  professionals having in-depth computer knowledge. Users are therefore     #
#  encouraged to load and test the software's suitability as regards their   #
#  requirements in conditions enabling the security of their systems and/or  #
#  data to be ensured and, more generally, to use and operate it in the      #
#  same conditions as regards security.                                      #
#                                                                            #
#  The fact that you are presently reading this means that you have had      #
#  knowledge of the CeCILL-C license and that you accept its terms.          #
#                                                                            #
##############################################################################

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
CMD=$(basename $0)
[ -f /etc/default/wckeysctl ] && source /etc/default/wckeysctl
[ -f /etc/slurm-llnl/slurmdbd.conf ] && source /etc/slurm-llnl/slurmdbd.conf

print_error () {
        echo -e "\e[00;31m$2\e[00m" 1>&2
        exit ${1}
}

print_msg () {
        echo -e "\e[00;34m$1\e[00m" 1>&2
}


### Block 0 ###
### Create temporaries files and directories ###
TMP_MNT_POINT=$(mktemp -d)
mount -t tmpfs -o size=20m tmpfs ${TMP_MNT_POINT}

WCKEYS_TMP_FILE=$(tempfile -d ${TMP_MNT_POINT})
ACCOUNTS_TMP_FILE=$(tempfile -d ${TMP_MNT_POINT})
TMP_FILE_MYSQL=$(tempfile -d ${TMP_MNT_POINT})
WCKEYS_INDB_TMP_FILE=$(tempfile -d ${TMP_MNT_POINT})
WCKEYS_ADD_TMP_FILE=$(tempfile -d ${TMP_MNT_POINT})
WCKEYS_DEL_TMP_FILE=$(tempfile -d ${TMP_MNT_POINT})

### Block 1 ###
### Generate wckeys file ####

nb=0
for CODES_PROJETS_FILE_CURRENT in ${PAREO_FILE}
do
  if [ -f "${CODES_PROJETS_FILE_CURRENT}" ]
  then
    ((nb++))
    CODES_PROJETS_LIST=$(awk -F';' '{print tolower($1)}' ${CODES_PROJETS_FILE_CURRENT} | sed 's/^[ \t]*//;s/[ \t]*$//' | sort -u)
    CODES_METIERS_FILE_CURRENT=$(echo ${CODES_FILE} | cut -f${nb} -d" ")
      if [ -f "${CODES_METIERS_FILE_CURRENT}" ]
      then
        CODES_METIERS_LIST=$(iconv -f 437 -t ascii//TRANSLIT ${CODES_METIERS_FILE_CURRENT} | \
        awk -F';' '{gsub (/[ )]$/, "", $1 ); print tolower($1)}' | \
        tr '[:blank:]' '_' | sed -r -e 's/[_]+/_/g' -e 's/^[_]+//g' -e 's/[_]+$//g' | sort -u)

        for project in ${CODES_PROJETS_LIST}
        do
          for application in ${CODES_METIERS_LIST}
          do
            echo "${project}:${application}"
          done >> ${WCKEYS_TMP_FILE}
        done
      else
        print_error 1 "File not found: ${CODES_METIERS_FILE_CURRENT}"
      fi
  else
    print_error 1 "File not found: ${CODES_PROJETS_FILE_CURRENT}"
  fi
done
sort -u ${WCKEYS_TMP_FILE} -o ${WCKEYS_FILE}

if [ -f "${SLURMDB_FILE}" ]
then
  source ${SLURMDB_FILE}
else
  print_error 1 "File not found: ${CODES_FILE}"
fi

### Block 2 ###
### Generate add and delete files ###

${SACCTMGR} -np list wckeys | awk -F'|' '{ print $1 }' | sort -u > ${WCKEYS_INDB_TMP_FILE}
comm -23 ${WCKEYS_INDB_TMP_FILE} ${WCKEYS_FILE} > ${WCKEYS_DEL_TMP_FILE}
comm -13 ${WCKEYS_INDB_TMP_FILE} ${WCKEYS_FILE} > ${WCKEYS_ADD_TMP_FILE}

### Block 3 ###
### Insert wckeys into slurm database ###
for key in $(cat ${WCKEYS_ADD_TMP_FILE})
do
  DATE=$(date "+%s")

cat > ${TMP_FILE_MYSQL} << EOF
UPDATE ${DB_NAME}.${CLUSTERNAME}_wckey_table SET deleted = 0 WHERE wckey_name = '${key}';
INSERT INTO ${DB_NAME}.${CLUSTERNAME}_wckey_table
  (creation_time, mod_time, wckey_name, user)
SELECT
  '${DATE}','${DATE}','${key}','root'
FROM ${DB_NAME}.${CLUSTERNAME}_wckey_table
WHERE '${key}' NOT IN
(
  SELECT wckey_name
  FROM ${DB_NAME}.${CLUSTERNAME}_wckey_table
)
LIMIT 1
EOF
  mysql --host=${StorageHost} --user=${StorageUser} --password=${StoragePass} < ${TMP_FILE_MYSQL}
  print_msg "Add new wckey= ${key}"
done


### Block 4 ###
### Delete wckeys from slurm database ###
for key in $(cat ${WCKEYS_DEL_TMP_FILE})
do
cat > ${TMP_FILE_MYSQL} << EOF
UPDATE ${DB_NAME}.${CLUSTERNAME}_wckey_table SET deleted = 1 WHERE wckey_name = '${key}';
EOF
  mysql --host=${StorageHost} --user=${StorageUser} --password=${StoragePass} < ${TMP_FILE_MYSQL}
  print_msg "Del old wckey= ${key}"
done

### Block 5 ###
### Clean system ###
umount ${TMP_MNT_POINT}
rm -rf  ${TMP_MNT_POINT}

