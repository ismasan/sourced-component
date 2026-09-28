flowchart LR
  c0["logger.output<br/>Any<br/><i>singleton, toredown</i>"]:::toredown
  c1["db.url<br/>String<br/><i>singleton, toredown</i>"]:::toredown
  c2["cache<br/>(Nil | Interface[get, set])<br/><i>singleton, toredown</i>"]:::toredown
  c3["logger<br/>Interface[info, debug]<br/><i>singleton, toredown</i>"]:::toredown
  c4["db<br/>Interface[insert, count]<br/><i>singleton, toredown</i>"]:::toredown
  c5["worker<br/>Worker<br/><i>singleton, toredown</i>"]:::toredown
  c6(["request_id<br/>String<br/><i>dynamic, toredown</i>"]):::toredown
  c0 --> c3
  c1 --> c4
  c3 --> c4
  c4 --> c5
  c3 --> c5
  classDef open fill:#f4f4f5,stroke:#71717a
  classDef prepared fill:#e0f2fe,stroke:#0284c7
  classDef built fill:#ede9fe,stroke:#7c3aed
  classDef started fill:#dcfce7,stroke:#16a34a
  classDef toredown fill:#e4e4e7,stroke:#52525b,color:#52525b
  classDef unregistered fill:#fef9c3,stroke:#ca8a04,stroke-dasharray:4 3
  classDef missing fill:#fee2e2,stroke:#dc2626,stroke-dasharray:4 3