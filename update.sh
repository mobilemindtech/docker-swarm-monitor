#!/bin/bash

# Copiar script principal
echo "📄 Copiando arquivos..."
cp monitor.tcl /opt/swarm-monitor/monitor.tcl 

# Tornar executável
chmod +x /opt/swarm-monitor/monitor.tcl

echo "Reiniciando serviço..."
sudo service swarm-monitor restart

echo "Update complete!"