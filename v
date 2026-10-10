#!/bin/bash
# Atajo para Oracle Cloud Shell: crea la VM gratuita de los servidores reintentando por capacidad.
curl -fsSL https://raw.githubusercontent.com/Alex-Robles26/linea-cero/main/servidor/crear_vm.sh -o ~/crear_vm.sh
nohup bash ~/crear_vm.sh > ~/crear_vm.log 2>&1 &
sleep 40; tail -8 ~/crear_vm.log
