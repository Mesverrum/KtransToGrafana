# Network Monitoring — Alert Reference

This document describes the automated alerts configured for network device monitoring.
All alerts use SNMP data collected via ktranslate.

---

## 1. Ping Packet Loss
**Fires after:** 2 minutes above threshold

```promql
avg by(`device_name`, `src_addr`) (`kentik_ping_PacketLossPct`)
```

Calculates the average ping packet loss percentage per device. Even low levels (5–10%) can degrade application performance and user experience.

---

## 2. Network Device CPU High
**Fires after:** 5 minutes above threshold

```promql
max by(`device_name`, `instrumentation_name`) (`kentik_snmp_CPU`)
```

Reports maximum CPU utilization per device. Sustained high CPU can cause packet drops and slow routing protocol convergence.

---

## 3. Network Device Memory High
**Fires after:** 5 minutes above threshold

```promql
max by(`device_name`, `instrumentation_name`) (`kentik_snmp_MemoryUtilization`)
```

Reports maximum memory utilization per device. High memory can cause process crashes or the device to drop routing table entries.

---

## 4. Network Interface Inbound Utilization High
**Fires after:** 10 minutes above threshold

```promql
max by(`device_name`, `if_interface_name`, `if_Speed`, `if_Description`) (
  `avg_over_time`(`kentik_snmp_IfInUtilization`{`if_OperStatus`="up"}[30m])
)
```

30-minute rolling average of inbound traffic utilization as a % of interface capacity, for all operationally-up interfaces. Sustained inbound saturation causes queuing, latency, and packet drops.

---

## 5. Network Interface Outbound Utilization High
**Fires after:** 10 minutes above threshold

```promql
max by(`device_name`, `if_interface_name`, `if_Speed`, `if_Description`) (
  `avg_over_time`(`kentik_snmp_IfOutUtilization`{`if_OperStatus`="up"}[30m])
)
```

Same as above, for outbound (egress) traffic. Commonly relevant on uplinks and WAN-facing interfaces.

---

## 6. Network Power Supply Status
**Fires:** Immediately (no duration window)

```promql
max by(`device_name`, `src_addr`, `entity_name`, `entity_model`, `entity_serial`, `fru_power_oper_status`) (
  `kentik_snmp_fru_power_oper_status`{`fru_power_admin_status`="on", `entity_name`=~".+"}
)
```

Monitors each administratively-enabled PSU's operational status. Fires when a PSU reports anything other than `on` (e.g. `offDenied`, `failed`). A lost PSU removes power redundancy.

---

## 7. Network Device Fan Failure
**Fires:** Immediately (no duration window)

```promql
max by(`device_name`, `src_addr`, `fan_descr`, `fan_state`, `entity_name`) (
  `kentik_snmp_fan_state`
)
```

Monitors every fan and fan tray per device. Fires when any fan reports a non-normal state. Fan failures reduce cooling and risk thermal shutdowns.

---

## 8. Network Device Temperature Abnormal
**Fires:** Immediately (no duration window)

```promql
max by(`device_name`, `src_addr`, `temp_descr`, `temp_state`, `temp_threshold`, `entity_name`) (
  `kentik_snmp_temp_state`
)
```

Monitors temperature sensors across each device (CPU, FPGA, air inlet/outlet, etc.). Fires when any sensor goes non-normal. Alert includes the sensor's configured threshold in °C.

---

## 9. Network Interface Down
**Fires:** Immediately (no duration window)

```promql
max by(`device_name`, `src_addr`, `if_interface_name`, `if_Description`, `if_Speed`, `if_OperStatus`) (
  `kentik_snmp_if_AdminStatus`{`if_OperStatus`="down"} == 1
)
unless on(`device_name`, `if_interface_name`) (
  max by(`device_name`, `if_interface_name`) (
    `kentik_snmp_if_AdminStatus`{`if_OperStatus`="down"} offset 5m == 1
  )
)
```

Detects interfaces that are admin-up but operationally down. The `unless` clause suppresses ports that were already down 5 minutes ago — so only **newly-down** interfaces fire an alert, avoiding persistent noise from known-unused ports.
