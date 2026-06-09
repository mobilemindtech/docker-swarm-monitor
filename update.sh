#!/bin/bash

set -e

echo "🚀 Atualizando Docker Swarm Monitor..."

# Verificar se está rodando como root
if [[ $EUID -ne 0 ]]; then
   echo "❌ Este script deve ser executado como root"
   exit 1
fi


# Copiar script principal
echo "📄 Copiando arquivos..."
cp monitor.tcl /opt/swarm-monitor/monitor.tcl 

# Tornar executável
chmod +x /opt/swarm-monitor/monitor.tcl

echo "Reiniciando serviço..."
sudo service swarm-monitor restart

echo "Update complete!"