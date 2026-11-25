#!/usr/bin/tclsh

# ==============================================================================
# Docker Swarm Monitor - Sistema de Monitoramento e Auto-Recovery
# ==============================================================================

package require http
package require tls
package require json
package require sqlite3
package require Tclx

http::register https 443 [list ::tls::socket -autoservername true]

proc log_message { level message } {
  set timestamp [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S"]
  puts "\[$timestamp\] \[$level\] $message"

  # Log crítico também vai para syslog
  if { $level eq "CRITICAL" || $level eq "ERROR" } {
    exec logger -t swarm_monitor "$level: $message"
  }
}

if { [file exists ./config.tcl] } {
  log_message "INFO" "Load local configs: ./config.tcl"
  source ./config.tcl
} elseif { [file exists /etc/swarm-monitor/config.tcl] } {
  log_message "INFO" "Load configs at /etc/swarm-monitor/config.tcl"
  source /etc/swarm-monitor/config.tcl
} else {
  log_message "CRITICAL" "File configs not found. Use in-memory configs"

  # Configurações para teste
  array set CONFIG {
    telegram_bot_token "SEU_BOT_TOKEN_AQUI"
    telegram_chat_id "SEU_CHAT_ID_AQUI"
    metrics_db "/var/log/swarm_metrics.db"
    http_port 9090
    collect_interval 10
    analysis_window 600
    memory_threshold_warning 85
    memory_threshold_critical 95
    cpu_threshold_warning 85
    cpu_threshold_critical 95
    disk_threshold_warning 85
    disk_threshold_critical 95
    critical_services_update 4gym_4gym
    service_update_stack_deploy_cmd "into ~/cluster, ./swr deploy 4gym"
    endpoint_monitor {https://www.4gym.com.br/error/failure}
  }
}

# Configurações opcionais (o config.tcl de produção pode não ter estas chaves)
#   stop_cooldown: segundos sem nova parada depois de parar um container. Dá tempo do container
#     subir (a inicialização de um app Java usa muita CPU) e da média da janela refletir a parada.
#   container_min_share: participação mínima (%) do container no recurso do servidor, na média da
#     janela, para ser parado. Abaixo disso o container não é a causa e nada é parado.
#   protected_services: padrões (glob) de nomes de container que nunca são parados (ex.: banco).
foreach { key value } {
  stop_cooldown 600
  container_min_share 20
  protected_services {}
} {
  if { ![info exists CONFIG($key)] } {
    set CONFIG($key) $value
  }
}

# Variáveis globais
set metrics_history {}
set last_notification {}
set http_server_socket ""
set last_stop_time 0

# docker stats mede CPU por núcleo (100% = 1 núcleo); para comparar com o servidor divide pelo nº de núcleos
if { [catch { exec nproc } cpu_count] || ![string is integer -strict $cpu_count] || $cpu_count < 1 } {
  set cpu_count 1
}

# ==============================================================================
# Funções de Configuração e Inicialização
# ==============================================================================

proc init_database { } {
  global CONFIG

  sqlite3 db $CONFIG(metrics_db)

  db eval {
    CREATE TABLE IF NOT EXISTS metrics (
    timestamp INTEGER PRIMARY KEY,
    hostname TEXT,
    cpu_usage REAL,
    memory_usage REAL,
    memory_total INTEGER,
    memory_available INTEGER,
    disk_usage REAL,
    load_avg REAL,
    docker_containers INTEGER,
    docker_services INTEGER,
    action_taken TEXT
    );

    CREATE INDEX IF NOT EXISTS idx_timestamp ON metrics(timestamp);
    CREATE INDEX IF NOT EXISTS idx_hostname ON metrics(hostname);
  }
}

# ==============================================================================
# Funções de Coleta de Métricas
# ==============================================================================

proc get_system_metrics { } {
  set metrics {}

  # Hostname
  set hostname [exec hostname]
  dict set metrics hostname $hostname

  # CPU Usage
  set cpu_usage [get_cpu_usage]
  dict set metrics cpu_usage $cpu_usage

  # Memory Usage
  set memory_info [get_memory_info]
  dict set metrics memory_usage [dict get $memory_info usage_percent]
  dict set metrics memory_total [dict get $memory_info total]
  dict set metrics memory_available [dict get $memory_info available]

  # Disk Usage
  set disk_usage [get_disk_usage]
  dict set metrics disk_usage $disk_usage

  # Load Average
  set load_avg [get_load_average]
  dict set metrics load_avg $load_avg

  # Docker Info
  set docker_info [get_docker_info]
  dict set metrics docker_containers [dict get $docker_info containers]
  dict set metrics docker_services [dict get $docker_info services]

  # Docker containers stats
  dict set metrics docker_containers_stats [get_containers_stats]

  # Timestamp
  dict set metrics timestamp [clock seconds]

  return $metrics
}

proc get_cpu_usage { } {
  # Usa vmstat para obter uso de CPU
  set output [exec vmstat 1 2]
  set lines [split $output "\n"]
  set last_line [lindex $lines end]
  set fields [regexp -all -inline {\S+} $last_line]

  # Campo 'id' (idle) é o último campo relevante
  if { [llength $fields] >= 15 } {
    set idle [lindex $fields 14]
    return [expr { 100.0 - $idle }]
  }
  return 0.0
}

proc get_memory_info { } {
  set meminfo [exec cat /proc/meminfo]
  set memory_data {}

  foreach line [split $meminfo "\n"] {
    if { [regexp {^(\w+):\s*(\d+)\s*kB} $line -> key value] } {
      dict set memory_data $key [expr { $value * 1024 }]
    }
  }

  set total [dict get $memory_data MemTotal]
  set available [dict get $memory_data MemAvailable]
  set used [expr { $total - $available }]
  set usage_percent [expr { ($used * 100.0) / $total }]

  return [dict create \
    total $total \
    available $available \
    used $used \
    usage_percent $usage_percent]
}

proc get_disk_usage { } {
  set output [exec df -h /]
  set lines [split $output "\n"]
  set data_line [lindex $lines 1]
  set fields [regexp -all -inline {\S+} $data_line]

  if { [llength $fields] >= 5 } {
    set usage_str [lindex $fields 4]
    return [string trimright $usage_str "%"]
  }
  return 0
}

proc get_load_average { } {
  set loadavg [exec cat /proc/loadavg]
  set fields [split $loadavg]
  return [lindex $fields 0]
}

proc get_docker_info { } {
  set containers 0
  set services 0

  if { ![catch { exec docker ps -q } container_ids] } {
    set containers [llength [split $container_ids "\n"]]
  }

  if { ![catch { exec docker service ls -q } service_ids] } {
    set services [llength [split $service_ids "\n"]]
  }

  return [dict create containers $containers services $services]
}

# Função para obter estatísticas de CPU dos containers
proc get_containers_stats { } {
  if { [catch { exec docker stats --no-stream --format "table {{.Container}} {{.CPUPerc}} {{.MemPerc}} {{.Name}}" } result] } {
    log_message "ERROR" "Falha ao executar docker stats: $result"
    return {}
  }

  set lines [split $result "\n"]
  set containers {}

  # Pular a primeira linha (cabeçalho)
  foreach line [lrange $lines 1 end] {
    if { $line eq "" } { continue }

    lassign $line container_id cpu_percent mem_percent container_name

    # Remover o símbolo % e converter para número
    set cpu_value [string trimright $cpu_percent "%"]
    set mem_value [string trimright $mem_percent "%"]

    set container [dict create \
      id $container_id \
      cpu_usage $cpu_value \
      memory_usage $mem_value \
      name $container_name]

    lappend containers $container
  }

  return $containers
}

proc is_protected { name } {
  global CONFIG
  foreach pattern $CONFIG(protected_services) {
    if { [string match $pattern $name] } {
      return 1
    }
  }
  return 0
}

# Escolhe o container a parar quando o servidor está crítico em CPU ou memória.
#
# - Média de cada container em toda a janela, não a leitura instantânea: um pico de 1 segundo
#   (GC, um job curto) não faz o container ser escolhido.
# - CPU convertida para participação no servidor (docker stats: 100% = 1 núcleo).
# - Só containers presentes na última coleta e com pelo menos metade das coletas da janela:
#   um container que acabou de (re)iniciar não é escolhido pela CPU da inicialização.
# - Só um container: o que mais pesa no recurso crítico, e só se pesar pelo menos
#   container_min_share% do servidor. Os demais seguem rodando.
#
# resource: "cpu" ou "memory". Retorna uma lista com 0 ou 1 container.
proc analyze_metrics_by_service { metrics_list resource } {
  global CONFIG cpu_count

  if { [llength $metrics_list] == 0 } {
    log_message "INFO" "no metrics for services found"
    return {}
  }

  set stats {}

  foreach metrics $metrics_list {
    foreach container [dict get $metrics docker_containers_stats] {
      set id [dict get $container id]
      set cpu [dict get $container cpu_usage]
      set memory [dict get $container memory_usage]

      if { ![string is double -strict $cpu] || ![string is double -strict $memory] } {
        continue
      }

      if { [dict exists $stats $id] } {
        dict with stats $id {
          set cpu_sum [expr { $cpu_sum + $cpu }]
          set memory_sum [expr { $memory_sum + $memory }]
          incr count
        }
      } else {
        dict set stats $id [dict create \
          id $id \
          name [dict get $container name] \
          cpu_sum $cpu \
          memory_sum $memory \
          count 1]
      }
    }
  }

  set running_ids {}
  foreach container [dict get [lindex $metrics_list end] docker_containers_stats] {
    lappend running_ids [dict get $container id]
  }

  set min_count [expr { max(1, [llength $metrics_list] / 2) }]
  set candidate {}
  set candidate_value -1

  foreach stat [dict values $stats] {
    set id [dict get $stat id]
    set name [dict get $stat name]
    set n [dict get $stat count]
    set avg_cpu [expr { double([dict get $stat cpu_sum]) / $n / $cpu_count }]
    set avg_memory [expr { double([dict get $stat memory_sum]) / $n }]

    log_message "INFO" "Média $name - CPU: [format %.1f $avg_cpu]% do servidor | Memory: [format %.1f $avg_memory]% | coletas: $n"

    if { $id ni $running_ids || $n < $min_count || [is_protected $name] } {
      continue
    }

    set value [expr { $resource eq "cpu" ? $avg_cpu : $avg_memory }]
    if { $value > $candidate_value } {
      set candidate_value $value
      set candidate [dict create \
        id $id \
        name $name \
        cpu_usage [format %.1f $avg_cpu] \
        memory_usage [format %.1f $avg_memory] \
        severity "critical"]
    }
  }

  if { $candidate eq {} || $candidate_value < $CONFIG(container_min_share) } {
    if { $candidate ne {} } {
      log_message "INFO" "Maior consumo de $resource: [dict get $candidate name] com [format %.1f $candidate_value]%, abaixo de $CONFIG(container_min_share)%: nenhum container parado"
    }
    return {}
  }

  set label [expr { $resource eq "cpu" ? "CPU" : "Memória" }]
  dict set candidate reason "[dict get $candidate name] - $label: [format %.1f $candidate_value]% do servidor (média da janela)"
  return [list $candidate]
}

# ==============================================================================
# Funções de Análise e Decisão
# ==============================================================================

proc analyze_metrics { metrics_list } {
  global CONFIG

  if { [llength $metrics_list] == 0 } {
    return [dict create action "none" severity "info"]
  }

  # Calcular médias dos últimos 5 minutos
  set cpu_sum 0.0
  set memory_sum 0.0
  set disk_sum 0.0
  set count 0
  set stats {}

  foreach metrics $metrics_list {
    set cpu_sum [expr { $cpu_sum + [dict get $metrics cpu_usage] }]
    set memory_sum [expr { $memory_sum + [dict get $metrics memory_usage] }]
    set disk_sum [expr { $disk_sum + [dict get $metrics disk_usage] }]
    incr count
  }

  if { $count == 0 } {
    return [dict create action "none" severity "info"]
  }

  set avg_cpu [expr { $cpu_sum / $count }]
  set avg_memory [expr { $memory_sum / $count }]
  set avg_disk [expr { $disk_sum / $count }]

  log_message "INFO" "Médias ${count} coletas - CPU: ${avg_cpu}% | Memory: ${avg_memory}% | Disk: ${avg_disk}%"

  # Determinar ação necessária
  set action "none"
  set severity "info"
  set reason ""

  # Verificar condições críticas
  if { $avg_memory >= $CONFIG(memory_threshold_critical) } {
    set action "restart_docker"
    set severity "critical"
    set reason "Memória crítica: [expr { int($avg_memory) }]%"
  } elseif { $avg_cpu >= $CONFIG(cpu_threshold_critical) } {
    set action "scale_down_services"
    set severity "critical"
    set reason "CPU crítico: [expr { int($avg_cpu) }]%"
  } elseif { $avg_disk >= $CONFIG(disk_threshold_critical) } {
    set action "cleanup_docker"
    set severity "critical"
    set reason "Disco crítico: [expr { int($avg_disk) }]%"
  } elseif { $avg_memory >= $CONFIG(memory_threshold_warning) } {
    set action "none"
    set severity "warning"
    set reason "Memória alta: [expr { int($avg_memory) }]%"
  } elseif { $avg_cpu >= $CONFIG(cpu_threshold_warning) } {
    set action "none"
    set severity "warning"
    set reason "CPU alto: [expr { int($avg_cpu) }]%"
  } elseif { $avg_disk >= $CONFIG(disk_threshold_warning) } {
    set action "cleanup_docker"
    set severity "warning"
    set reason "Disco alto: [expr { int($avg_disk) }]%"
  }

  # Só CPU e memória levam a parar um container, e o container é escolhido pelo recurso que
  # está crítico. Disco crítico só notifica: parar container não libera disco.
  set containers_to_down {}

  if { $severity == "critical" } {
    switch $action {
      "restart_docker" {
        set containers_to_down [analyze_metrics_by_service $metrics_list memory]
      }
      "scale_down_services" {
        set containers_to_down [analyze_metrics_by_service $metrics_list cpu]
      }
    }
  }

  return [dict create \
    action $action \
    severity $severity \
    reason $reason \
    avg_cpu $avg_cpu \
    avg_memory $avg_memory \
    avg_disk $avg_disk \
    containers_to_down $containers_to_down]
}

# ==============================================================================
# Funções de Ação Corretiva
# ==============================================================================

proc execute_action { analysis } {
  global CONFIG last_stop_time

  set action [dict get $analysis action]
  set severity [dict get $analysis severity]
  set reason [dict get $analysis reason]
  set containers_to_down [dict get $analysis containers_to_down]
  set action_executed false

  if { $severity ne "critical" } {
    log_message "WARNING" "$reason"
    return false
  }

  # Depois de parar um container, espera ele subir e a média refletir a parada antes de agir de novo.
  # Sem isso a média da janela continua crítica e o monitor para container atrás de container
  # (inclusive o mesmo, enquanto ele ainda está inicializando).
  set since_last_stop [expr { [clock seconds] - $last_stop_time }]
  if { $since_last_stop < $CONFIG(stop_cooldown) } {
    log_message "INFO" "$reason - aguardando ${since_last_stop}s/$CONFIG(stop_cooldown)s desde a última parada"
    return false
  }

  if { [llength $containers_to_down] > 0 } {
    foreach container $containers_to_down {
      set container_reason [dict get $container reason]
      set service_name [dict get $container name]
      set id [dict get $container id]
      set cpu_usage [dict get $container cpu_usage]
      set memory_usage [dict get $container memory_usage]

      send_telegram_notification "critical" "stoping_container" "$reason. $container_reason"

      if {[stop_container $service_name $id $cpu_usage $memory_usage]} {
        send_telegram_notification "critical" "stoped_container" "container ${service_name} sucessfully stoped"
        set action_executed true
      } else {
        send_telegram_notification "critical" "stop_container_error" "canot stop container ${service_name}"
      }
    }

    # conta o cooldown mesmo se o stop falhar, para não tentar a cada coleta
    set last_stop_time [clock seconds]
  } elseif { $action eq "cleanup_docker" } {
    send_telegram_notification "critical" "disk_critical" $reason
  } else {
    send_telegram_notification "critical" "server_exhausted" "$reason. The server is exhausted, but no services were found to stop"
  }

  #switch $action {
  #  "scale_down_services" {
  #    log_message "ACTION" "Serviços redimensionados - $reason"
  #    #scale_down_services
  #    try {
  #      if { ![update_services $severity $reason] } {
  #        return false
  #      }
  #      return true
  #    } on error err {
  #      log_message "ERROR" "Ocorreu um erro ao executar atualização de serviços: $err"
  #      send_telegram_notification $severity $action "Ocorreu um erro ao executar atualização de serviços: $err"
  #    }
  #    return false
  #  }
  #  "restart_docker" {
  #    #restart_docker_service
  #    log_message "ACTION" "Docker reiniciado - $reason"
  #    set action_executed true
  #  }
  #  "cleanup_docker" {
  #    #cleanup_docker_resources
  #    log_message "ACTION" "Limpeza do Docker executada - $reason"
  #    set action_executed true
  #  }
  #  "none" {
  #    return false
  #  }
  #}

  # Notificar via Telegram
  #send_telegram_notification $severity $action $reason

  return $action_executed
}

proc update_services { severity reason } {
  global CONFIG

  set critical_services_update [split $CONFIG(critical_services_update) ,]
  set stack_deploy_cmds [split $CONFIG(service_update_stack_deploy_cmd) ,]

  foreach cmd $stack_deploy_cmds {
    log_message "INFO" "run stack deploy before update. CMD: $cmd"
    try {
      if { [string match "into *" $cmd] } {
        cd [lindex [split $cmd " "] 1]
      } else {
        exec bash -c $cmd
      }
    } on error err {
      log_message "ERROR" "error on run stack deploy before update. CMD: $cmd, error: $err"
      send_telegram_notification $severity stack_deploy "Ocorreu um erro ao atualizar stack antes do update. CMD $cmd, Error: $err"
    }
  }

  foreach service_name $critical_services_update {
    set updating [check_service_updating $service_name]
    set starting [check_service_starting $service_name]

    if { !$updating && !$starting } {
      if { ![run_service_update $service_name $severity $reason] } {
        return false
      }
    } else {
      if { $updating } {
        log_message "INFO" "service updating in progress for service $service_name"
      } else {
        log_message "INFO" "service starting in progress for service $service_name"
      }
    }
  }
  return true
}

proc run_service_update { service_name severity reason } {
  try {
    set update_label "update service $service_name"

    send_telegram_notification $severity $update_label $reason

    set start_time [clock seconds]

    exec docker service update --force $service_name

    set elapsed [expr { [clock seconds] - $start_time }]

    if { $elapsed > 60 } {
      set elapsed_label [expr { $elapsed / 60 }]
      set elapsed_label "${elapsed_label},[expr { $elapsed % 60 }]min"
    } else {
      set elapsed_label "${elapsed}seg"
    }

    log_message "INFO" "Serviço $service_name atualizado com sucesso em ${elapsed_label}."
    send_telegram_notification $severity $update_label "Serviço atualizado em ${elapsed_label}"
    return true
  } on error err {
    log_message "ERROR" "Ocorreu um erro ao atualizar serviço: $err"
    send_telegram_notification $severity $update_label "Ocorreu um erro ao atualizar serviço: $err"
    return false
  }
}

proc check_service_starting { service_name } {
  set desired [exec docker service inspect --format "{{.Spec.Mode.Replicated.Replicas}}" $service_name]
  set running [exec docker service ps --filter "desired-state=running" --format "{{.CurrentState}}" $service_name | grep -c "Running"]
  return [expr { $running != $desired }]
}

proc check_service_updating { service_name } {
  set result [exec docker service inspect $service_name --format "{{if .UpdateStatus }} {{.UpdateStatus.State}} {{end}}"]
  return [expr { $result == "updating" }]
}

proc scale_down_services { } {
  log_message "INFO" "Iniciando redimensionamento de serviços..."

  # Listar serviços com múltiplas réplicas
  if { ![catch { exec docker service ls --format "{{.Name}} {{.Replicas}}" } services_output] } {
    foreach line [split $services_output "\n"] {
      if { [regexp {^(\S+)\s+(\d+)/\d+} $line -> service_name current_replicas] } {
        if { $current_replicas > 1 } {
          set new_replicas [expr { $current_replicas - 1 }]
          log_message "INFO" "Reduzindo $service_name de $current_replicas para $new_replicas réplicas"
          catch { exec docker service scale ${service_name}=${new_replicas} }
        }
      }
    }
  }
}

# Função para parar um container
proc stop_container { container_name container_id cpu_usage memory_usage } {
  log_message "INFO" "Parando container $container_name ($container_id) - CPU: ${cpu_usage}%, Memory: ${memory_usage}%"

  if { [catch { exec docker stop $container_id } result] } {
    log_message "ERROR" "Falha ao parar container $container_name: $result"
    return 0
  } else {
    log_message "INFO" "Container $container_name parado com sucesso"
    return 1
  }
}

proc restart_docker_service { } {
  log_message "CRITICAL" "Reiniciando serviço Docker..."
  catch { exec systemctl restart docker }
  after 10000 ;# Aguarda 10 segundos

  # Verificar se o Docker está rodando
  if { [catch { exec docker info }] } {
    log_message "ERROR" "Falha ao reiniciar Docker, tentando novamente..."
    catch { exec systemctl start docker }
  }
}

proc cleanup_docker_resources { } {
  log_message "INFO" "Iniciando limpeza de recursos Docker..."

  # Remover containers parados
  catch { exec docker container prune -f }

  # Remover imagens não utilizadas
  catch { exec docker image prune -f }

  # Remover volumes não utilizados
  catch { exec docker volume prune -f }

  # Remover redes não utilizadas
  catch { exec docker network prune -f }

  log_message "INFO" "Limpeza concluída"
}

# ==============================================================================
# Funções de Notificação
# ==============================================================================

proc send_telegram_notification { severity action reason } {
  global CONFIG last_notification

  set current_time [clock seconds]
  set notification_key "${severity}_${action}_${reason}"

  # Evitar spam - não enviar a mesma notificação em menos de 5 minutos
  if { [dict exists $last_notification $notification_key] } {
    set last_time [dict get $last_notification $notification_key]
    if { ($current_time - $last_time) < 300 } {
      return
    }
  }

  set hostname [exec hostname]
  set timestamp [clock format $current_time -format "%Y/%m/%d %H:%M:%S"]

  # Emojis baseados na severidade
  switch $severity {
    "critical" { set emoji "🚨" }
    "warning" { set emoji "⚠️" }
    "info" { set emoji "ℹ️" }
    default { set emoji "📊" }
  }

  # telegram markdown cannot have - or _
  set message "${emoji} *Docker Swarm Monitor*\n\n"
  append message "*Host:* [lindex [split $hostname .] 0]\n"
  append message "*Timestamp:* $timestamp\n"
  append message "*Severidade:* [string toupper $severity]\n"
  append message "*Acao:* [normalize_msg $action]\n"
  append message "*Motivo:* [normalize_msg $reason]"

  # Enviar para Telegram
  set url "https://api.telegram.org/bot$CONFIG(telegram_bot_token)/sendMessage"
  set data [http::formatQuery chat_id $CONFIG(telegram_chat_id) parse_mode MarkdownV2 text $message]

  try {
    set token [http::geturl $url -query $data -timeout 10000]
    dict set last_notification $notification_key $current_time
    log_message "INFO" "Notificação Telegram enviada \[[::http::status $token]\]: $action"
    http::cleanup $token
  } on error err {
    log_message "ERROR" "Falha ao enviar notificação Telegram: $err"
  }
}

proc monitore_endepoins {} {

  global CONFIG

  set endpoints $CONFIG(endpoint_monitor)

  foreach url $endpoints {

    try {
      set token [http::geturl $url -timeout 10000]
      set resp [http::data $token]

      if {[expr $resp > 15]} {
        set reason "A URL $url retornou $resp falhas, o serviço precisa ser reiniciado"
        execute_action [list action scale_down_services severity critical reason $reason]
      }

      http::cleanup $token
    } on error err {
      log_message "ERROR" "Falha ao verificar endpoint $url: $err"
    }

  }
}

proc normalize_msg { msg } {
  set msg [regsub -all {_} $msg {\_}]
  set msg [regsub -all {\.} $msg {\.}]
  return $msg
}

# ==============================================================================
# Servidor HTTP para Métricas (Grafana)
# ==============================================================================

proc start_http_server { } {
  global CONFIG http_server_socket

  set http_server_socket [socket -server http_request_accept $CONFIG(http_port)]
  log_message "INFO" "Servidor HTTP iniciado na porta $CONFIG(http_port)"
}

proc http_request_accept { sock host port } {
  chan configure $sock -blocking 0 -buffering line
  chan event $sock readable [list handle_http_request $sock]
}

proc handle_http_request { sock } {
  #fconfigure $sock -buffering line

  set request [gets $sock]

  # Ler headers (ignora o conteúdo por simplicidade)
  while { [gets $sock line] > 0 } { }

  if { [regexp {^GET (/\w+)} $request -> path] } {
    log_message "INFO" "Web app: GET $path"
    switch $path {
      "/metrics" {
        send_prometheus_metrics $sock
      }
      "/health" {
        send_health_check $sock
      }
      default {
        send_http_response $sock "404 Not Found" "Endpoint não encontrado"
      }
    }
  } else {
    send_http_response $sock "400 Bad Request" "Requisição inválida"
  }

  catch { close $sock }
}

proc send_prometheus_metrics { sock } {
  global CONFIG

  # Obter métricas atuais
  set current_metrics [get_system_metrics]
  set hostname [lindex [split [dict get $current_metrics hostname] .] 0]

  set response "HTTP/1.1 200 OK\n"
  append response "Content-Type: text/plain\n"
  append response "Connection: close\n\n"

  # Métricas no formato Prometheus
  #append response "# HELP swarm_cpu_usage_percent CPU usage percentage\n"
  #append response "# TYPE swarm_cpu_usage_percent gauge\n"
  append response "swarm_cpu_usage_percent{hostname=\"$hostname\"} [dict get $current_metrics cpu_usage]\n"

  #append response "# HELP swarm_memory_usage_percent Memory usage percentage\n"
  #append response "# TYPE swarm_memory_usage_percent gauge\n"
  append response "swarm_memory_usage_percent{hostname=\"$hostname\"} [dict get $current_metrics memory_usage]\n"

  #append response "# HELP swarm_disk_usage_percent Disk usage percentage\n"
  #append response "# TYPE swarm_disk_usage_percent gauge\n"
  append response "swarm_disk_usage_percent{hostname=\"$hostname\"} [dict get $current_metrics disk_usage]\n"

  #append response "# HELP swarm_load_average System load average\n"
  #append response "# TYPE swarm_load_average gauge\n"
  append response "swarm_load_average{hostname=\"$hostname\"} [dict get $current_metrics load_avg]\n"

  #append response "# HELP swarm_containers_total Total number of containers\n"
  #append response "# TYPE swarm_containers_total gauge\n"
  append response "swarm_containers_total{hostname=\"$hostname\"} [dict get $current_metrics docker_containers]\n"

  #append response "# HELP swarm_services_total Total number of services\n"
  #append response "# TYPE swarm_services_total gauge\n"
  append response "swarm_services_total{hostname=\"$hostname\"} [dict get $current_metrics docker_services]\n"

  puts -nonewline $sock $response
}

proc send_health_check { sock } {
  set response "HTTP/1.1 200 OK\n"
  append response "Content-Type: application/json\n"
  append response "Connection: close\n\n"
  append response "{\"status\":\"healthy\",\"timestamp\":[clock seconds]}\n"

  puts -nonewline $sock $response
}

proc send_http_response { sock status message } {
  set response "HTTP/1.1 $status\n"
  append response "Content-Type: text/plain\n"
  append response "Connection: close\n\n"
  append response "$message\n"

  puts -nonewline $sock $response
}

# ==============================================================================
# Funções de Armazenamento
# ==============================================================================

proc store_metrics { metrics action_taken } {
  set timestamp [dict get $metrics timestamp]
  set hostname [dict get $metrics hostname]
  set cpu_usage [dict get $metrics cpu_usage]
  set memory_usage [dict get $metrics memory_usage]
  set memory_total [dict get $metrics memory_total]
  set memory_available [dict get $metrics memory_available]
  set disk_usage [dict get $metrics disk_usage]
  set load_avg [dict get $metrics load_avg]
  set docker_containers [dict get $metrics docker_containers]
  set docker_services [dict get $metrics docker_services]

  db eval {
    INSERT INTO metrics (
    timestamp, hostname, cpu_usage, memory_usage, memory_total,
    memory_available, disk_usage, load_avg, docker_containers,
    docker_services, action_taken
    ) VALUES (
    $timestamp, $hostname, $cpu_usage, $memory_usage, $memory_total,
    $memory_available, $disk_usage, $load_avg, $docker_containers,
    $docker_services, $action_taken
    )
  }

  # Limpar dados antigos (manter apenas 7 dias)
  set week_ago [expr { [clock seconds] - 604800 }]
  db eval {DELETE FROM metrics WHERE timestamp < $week_ago}
}

# ==============================================================================
# Loop Principal
# ==============================================================================

proc main_loop { } {
  global CONFIG metrics_history
  set start_time [clock seconds]

  # Coletar métricas
  set current_metrics [get_system_metrics]

  # Adicionar à história
  lappend metrics_history $current_metrics

  # Manter apenas os últimos 5 minutos de dados
  set window_start [expr { $start_time - $CONFIG(analysis_window) }]
  set filtered_history {}
  foreach metrics $metrics_history {
    if { [dict get $metrics timestamp] >= $window_start } {
      lappend filtered_history $metrics
    }
  }
  set metrics_history $filtered_history

  set metrics_count [llength $filtered_history]
  set min_metrics_to_analyze [expr { $CONFIG(analysis_window) / $CONFIG(collect_interval) }]

  if { $metrics_count < $min_metrics_to_analyze } {
    log_message "INFO" "Metricas insuficiêntes para analise. Coletas: ${metrics_count}X Necessário: ${min_metrics_to_analyze}X"
    schedule_next $start_time
    return
  }

  # Analisar métricas se temos dados suficientes
  set analysis [analyze_metrics $metrics_history]
  set action_taken [dict get $analysis action]

  # Executar ação se necessário
  if { $action_taken ne "none" } {
    if { [execute_action $analysis] } {
     # reset metrics if execute action
      set metrics_history {}
    }
  }

  #monitore_endepoins

  # Armazenar métricas
  #store_metrics $current_metrics $action_taken

  schedule_next $start_time
}

proc schedule_next { start_time } {
  global CONFIG
  # Calcular tempo de espera
  set elapsed [expr { [clock seconds] - $start_time }]
  set sleep_time [expr { $CONFIG(collect_interval) - $elapsed }]
  after [expr { $sleep_time * 1000 }] { main_loop }
}

# ==============================================================================
# Tratamento de Sinais e Cleanup
# ==============================================================================

proc cleanup_and_exit { } {
  global http_server_socket

  log_message "INFO" "Finalizando monitor..."

  if { $http_server_socket ne "" } {
    catch { close $http_server_socket }
  }

  #catch {db close}
  exit 0
}

# Capturar sinais de interrupção
signal trap {SIGINT SIGTERM} cleanup_and_exit

# ==============================================================================
# Inicialização
# ==============================================================================

proc main { } {
  log_message "INFO" "Iniciando Docker Swarm Monitor"

  # Verificar se está rodando como root
  if { [exec id -u] != 0 } {
    log_message "ERROR" "Este script deve ser executado como root"
    exit 1
  }

  # Inicializar componentes
  #init_database
  start_http_server

  # Enviar notificação de inicialização
  send_telegram_notification "info" "monitor_started" "Monitor iniciado com sucesso"

  # Iniciar loop principal
  log_message "INFO" "Iniciando loop principal de monitoramento"
  main_loop
}

# Executar se chamado diretamente
if { [info exists argv0] && $argv0 eq [info script] } {
  main
  vwait forever
}