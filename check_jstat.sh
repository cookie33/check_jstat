#!/usr/bin/env bash
#
# A simple Nagios command that check some statistics of a JAVA JVM.
#
# It first checks that the process specified by its pid (-p) or its
# service name (-s) (assuming there is a /var/run/<name>.pid file
# holding its pid) is running and is a java process.
# It then calls jstat -gc and jstat -gccapacity to catch current and
# maximum 'heap' and 'perm' sizes.
# What is called 'heap' here is the edden + old generation space,
# while 'perm' represents the permanent generation space or metaspace
# for java 1.8.
# If specified (with -w and -c options) values can be checked with
# WARNING or CRITICAL thresholds (apply to both heap and perm regions).
# This plugin also attaches performance data to the output:
#  pid=<pid>
#  heap=<heap-size-used>;<heap-max-size>;<%ratio>;<warning-threshold-%ratio>;<critical-threshold-%ratio>
#  perm=<perm-size-used>;<perm-max-size>;<%ratio>;<warning-threshold-%ratio>;<critical-threshold-%ratio>
#
#
# Created: 2012, June
# By: Eric Blanchard
# License: LGPL v2.1
#
# extended by Robert Verkerk


# Usage helper for this script
usage() {
    typeset prog="${1:-check_jstat.sh}"
    echo "Usage: $prog -v";
    echo "       Print version and exit"
    echo "Usage: $prog -h";
    echo "      Print this help and exit"
    echo "Usage: $prog -p <pid> [-w <%ratio>] [-c <%ratio>] [-P <java-home>]";
    echo "Usage: $prog -s <service> [-w <%ratio>] [-c <%ratio>] [-P <java-home>]";
    echo "Usage: $prog -j <java-name> [-w <%ratio>] [-c <%ratio>] [-P <java-home>]";
    echo "Usage: $prog -J <java-name> [-w <%ratio>] [-c <%ratio>] [-P <java-home>]";
    echo "       -p <pid>       the PID of process to monitor, might be multiple times entered"
    echo "       -s <service>   the service name of process to monitor"
    echo "       -j <java-name> the java app (see jps) process to monitor"
    echo "                      if this name in blank (-j '') any java app is"
    echo "                      looked for (as long there is only one)"
    echo "       -J <java-name> same as -j but checks on 'jps -v' output"
    echo "       -P <java-home> use this java installation path"
    echo "       -w <%>         the warning threshold ratio current/max in % (defaults to 90)"
    echo "       -c <%>         the critical threshold ratio current/max in % (defaults to 95)"
}

VERSION='1.5'
service=''
pid=''
ws=90
cs=95
use_jps=0
jps_verbose=0
java_home=''
exit_status=0
critical_string=""
warning_string=""
ok_string=""
perfdata=""

while getopts hvp:s:j:J:P:w:c: opt ; do
    case ${opt} in
    v)  echo "$0 version $VERSION"
        exit 0
        ;;
    h)  usage $0
        exit 3
        ;;
    p)  pidlist+=("${OPTARG}")
        ;;
    s)  service="${OPTARG}"
        ;;
    j)  java_name="${OPTARG}"
        use_jps=1
        ;;
    J)  java_name="${OPTARG}"
        use_jps=1
        jps_verbose=1
        ;;
    P)  java_home="${OPTARG}"
        ;;
    w)  ws="${OPTARG}"
        ;;
    c)  cs="${OPTARG}"
        ;;
    esac
done

if [ -z "$pidlist" -a -z "$service" -a $use_jps -eq 0 ] ; then
    echo "One of -p, -s or -j parameter must be provided"
    usage $0
    exit 3
fi

if [ -n "$pidlist" -a -n "$service" ] ; then
    echo "Only one of -p or -s parameter must be provided"
    usage $0
    exit 3
fi
if [ -n "$pidlist" -a $use_jps -eq 1 ] ; then
    echo "Only one of -p or -j parameter must be provided"
    usage $0
    exit 3
fi
if [ -n "$service" -a $use_jps -eq 1 ] ; then
    echo "Only one of -s or -j parameter must be provided"
    usage $0
    exit 3
fi

if [ -n "${java_home}" ] ; then
    if [ -x "${java_home}/bin/jstat" ] ; then
        PATH="${java_home}/bin:${PATH}"
    else
        echo "jstat not found in ${java_home}/bin"
        usage $0
        exit 3
    fi
fi

if [ $use_jps -eq 1 ] ; then
    if [ -n "$java_name" ] ; then
        if [ "${jps_verbose}" = "1" ] ; then
            java=$(jps -v | grep "$java_name" 2>/dev/null)
        else
            java=$(jps | grep "$java_name" 2>/dev/null)
        fi
    else
        java=$(jps | grep -v Jps 2>/dev/null)
    fi
    java_count=$(echo "$java" | wc -l)
    if [ -z "$java" -o "$java_count" != "1" ] ; then
        echo "UNKNOWN: No (or multiple) java app found"
        exit 3
    fi
    pidlist+=($(echo "$java" | cut -d ' ' -f 1))
    label=${java_name:-$(echo "$java" | cut -d ' ' -f 2)}
elif [ -n "$service" ] ; then
    if [ ! -r /var/run/${service}.pid ] ; then
        echo "/var/run/${service}.pid not found"
        exit 3
    fi
    pidlist+=($(cat /var/run/${service}.pid))
    label=$service
else
    label=$pid
fi

for pid in "${pidlist[@]}"; do
    error_status="false"
    if [ $use_jps -eq 1 -o -n "$service" ]; then
        #label is defined
        temp="bla"
    else
        label=$pid
    fi
    
    ps -p "$pid" > /dev/null
    if [ "$?" != "0" ] ; then
        critical_string="${critical_string}process pid[$pid] not found, "
        exit_status=2
        error_status="true"
    else
        if [ -d /proc/$pid ] ; then
            proc_name=$(cat /proc/$pid/status | grep 'Name:' | sed -e 's/Name:[ \t]*//')
            if [ "$proc_name" != "java" ] ; then
                critical_string="${critical_string}process pid[$pid] seems not to be a JAVA application, "
                exit_status=2
                error_status="true"
            fi
        fi
    fi

    if [ "${error_status}" == "false" ] ; then 
        gc=$(jstat -gc $pid | tail -1 | sed -e 's/[ ][ ]*/ /g')
        if [ -z "$gc" ]; then
            critical_string="${critical_string}Can't get GC statistics, "
            exit_status=2
            error_status="true"
        fi
    fi

    if [ "${error_status}" == "false" ] ; then 
        #echo "gc=$gc"
        set -- $gc
        eu=$(($(expr "${6}" : '\([0-9]*\)')*1024))
        ou=$(($(expr "${8}" : '\([0-9]*\)')*1024))
        pu=$(($(expr "${10}" : '\([0-9]*\)')*1024))
    fi
 
    if [ "${error_status}" == "false" ] ; then 
        gccapacity=$(jstat -gccapacity $pid | tail -1 | sed -e 's/[ ][ ]*/ /g')
        if [ -z "$gccapacity" ]; then
            critical_string="${critical_string}Can't get GC capacity, "
            exit_status=2
            error_status="true"
        fi
    fi

    if [ "${error_status}" == "false" ] ; then 
        #echo "gccapacity=$gccapacity"
        set -- $gccapacity
        ygcmx=$(($(expr "${2}" : '\([0-9]*\)')*1024))
        ogcmx=$(($(expr "${8}" : '\([0-9]*\)')*1024))
        pgcmx=$(($(expr "${12}" : '\([0-9]*\)')*1024))

        #echo "eu=${eu}k ygcmx=${ygcmx}k"
        #echo "ou=${ou}k ogcmx=${ogcmx}k"
        #echo "pu=${pu}k pgcmx=${pgcmx}k"

        heap=$((($eu + $ou)))
        heapmx=$((($ygcmx + $ogcmx)))
        heapratio=$((($heap * 100) / $heapmx))
        permratio=$((($pu * 100) / $pgcmx))

        heapw=$(($heapmx * $ws / 100))
        heapc=$(($heapmx * $cs / 100))
        permw=$(($pgcmx * $ws / 100))
        permc=$(($pgcmx * $cs / 100))

        #echo "youg+old=${heap}k, (Max=${heapmx}k, current=${heapratio}%)"
        #echo "perm=${pu}k, (Max=${pgcmx}k, current=${permratio}%)"


        #perfdata="pid=$pid heap=$heap;$heapmx;$heapratio;$ws;$cs perm=$pu;$pgcmx;$permratio;$ws;$cs"
        #perfdata="pid=$pid"
        perfdata="${perfdata} ${label}_heap=${heap}B;$heapw;$heapc;0;$heapmx"
        perfdata="${perfdata} ${label}_heap_ratio=${heapratio}%;$ws;$cs;0;100"
        perfdata="${perfdata} ${label}_perm=${pu}B;$permw;$permc;0;$pgcmx"
        perfdata="${perfdata} ${label}_perm_ratio=${permratio}%;$ws;$cs;0;100"

        if [ $cs -gt 0 -a $permratio -ge $cs -a "${error_status}" == "false" ]; then
            #echo "CRITICAL: jstat process $label critical PermGen (${permratio}% of MaxPermSize)|$perfdata"
            critical_string="${critical_string}jstat process $label critical PermGen (${permratio}% of MaxPermSize), "
            error_status="true"
            exit_status=2
        fi

        if [ $cs -gt 0 -a $heapratio -ge $cs -a "${error_status}" == "false" ]; then
            #echo "CRITICAL: jstat process $label critical Heap (${heapratio}% of MaxHeapSize)|$perfdata"
            critical_string="${critical_string}jstat process $label critical Heap (${heapratio}% of MaxHeapSize), "
            exit_status=2
            error_status="true"
        fi

        if [ $ws -gt 0 -a $permratio -ge $ws -a "${error_status}" == "false" ]; then
            #echo "WARNING: jstat process $label warning PermGen (${permratio}% of MaxPermSize)|$perfdata"
            warning_string="${warning_string}jstat process $label warning PermGen (${permratio}% of MaxPermSize), "
            error_status="true"
            if [ ${exit_status} -le 1 ]; then
                exit_status=1
            fi
        fi

        if [ $ws -gt 0 -a $heapratio -ge $ws -a "${error_status}" == "false" ]; then
            #echo "WARNING: jstat process $label warning Heap (${heapratio}% of MaxHeapSize)|$perfdata"
            warning_string="${warning_string}jstat process $label warning Heap (${heapratio}% of MaxHeapSize), "
            error_status="true"
            if [ ${exit_status} -le 1 ]; then
                exit_status=1
            fi
        fi

        if [ ${exit_status} -eq 0 ]; then
            OK=true
            ok_string="${ok_string}jstat process $label alive, "
        fi 
    fi 

done

case ${exit_status} in
2) echo "CRITICAL:${critical_string} WARNING:${warning_string} OK:${ok_string}|$perfdata" 
   exit ${exit_status}
   ;;
1) echo "WARNING:${warning_string} OK:${ok_string}|$perfdata" 
   exit ${exit_status}
   ;;
*) echo "OK:${ok_string}|$perfdata"
   exit ${exit_status}
   ;;
esac

# That's all folks !
