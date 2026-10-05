#!/usr/bin/env bash
 
# if there are existing sessions, ask which session to connect to, otherwise create a new one
ZJ_SESSIONS=$(zellij list-sessions)
NR_SESSIONS=$(echo "${ZJ_SESSIONS}" | wc -l)

if [ "${NR_SESSIONS}" -ge 2 ]; then
    ZJ_SELECTED=$(echo "${ZJ_SESSIONS}" | sk --ansi --no-sort --tac --reverse | cut -f 1 -d " ")
    if [ -n "${ZJ_SELECTED}" ]; then
        zellij attach --create "${ZJ_SELECTED}"
    fi
else
    zellij attach --create
fi
