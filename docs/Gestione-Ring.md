# Gestione Ring Intune

Modulo derivato da `Assegna-PC-Orfani-Ring-Intune.ps1`, con accesso del wrapper,
operazioni asincrone, controlli di identita e consultazione GLPI condivisa.

## Selezione gruppi

Da Impostazioni → Ring Intune → Seleziona gruppi da Entra usare Carica gruppi
Entra. Serve prima Accesso dal wrapper con lettura dispositivi e gruppi
disponibili. La ricerca usa l'inizio del nome; il filtro vuoto legge tutti i
gruppi, con paginazione completa. Non apre un secondo accesso Microsoft.

- **Controlla**: il gruppo contribuisce a determinare se un PC e gia assegnato.
- **Destinazione**: il gruppo puo essere scelto per aggiungere PC, se statico,
  cloud, di sicurezza, non abilitato alla posta e non assegnabile a ruoli.
- **Etichetta**: nome breve univoco mostrato per la scelta del Ring.

Si salvano ID, nome, etichetta e scelta destinazione. Gli ID conservano
l'associazione anche dopo una rinomina del gruppo. Nessun gruppo e preselezionato: **Ring99 e escluso**. La prima volta scegliere
esplicitamente i gruppi dalle impostazioni; le installazioni esistenti non
ricevono gruppi assegnati automaticamente. Un nome configurato senza ID
viene risolto solo se univoco fino alla selezione per ID nelle impostazioni. I gruppi non selezionati non entrano
nel calcolo. Un gruppo mancante, duplicato per nome o non leggibile interrompe
la ricerca: non viene ignorato e non produce falsi orfani.

## Lettura e assegnazione

Aggiorna dati / F5 legge i gruppi selezionati, tutte le loro appartenenze
transitive e i dispositivi Entra. I candidati sono Windows, ServerAd, Corporate,
gestiti MDM e abilitati. Le appartenenze sono confrontate con **Object ID
Entra**, non con Device ID. La vista iniziale mostra gli orfani; i filtri
permettono di consultare anche gia assegnati, appartenenze multiple e anomalie
GLPI. I contatori dei gruppi considerano gli oggetti transitivi letti.

Intune arricchisce l'inventario tramite Azure AD Device ID. GLPI usa seriale
Intune quando disponibile, altrimenti nome esatto, e mostra ID, nome effettivo,
stato, gruppo, CENSITO e inventario nei dettagli. Duplicati, conflitti seriali
e fonti non verificabili sono espliciti. Il modulo consulta GLPI: assegnare un
Ring aggiunge l'appartenenza Entra e non modifica la scheda GLPI.

Scegliere manualmente un Ring nelle righe degli orfani o impostarlo sulle
righe selezionate. Verifica assegnazioni prepara una lista concreta di PC,
Object ID e gruppi; Applica assegnazioni richiede conferma. Il piano privato
scade dopo cinque minuti ed e utilizzabile una sola volta. Prima di ogni
aggiunta vengono rilette identita e caratteristiche dei gruppi, requisiti del
dispositivo e appartenenze a tutti i gruppi monitorati. Un PC nel frattempo
assegnato non viene spostato. Nessuna appartenenza viene rimossa.

Dopo POST viene verificata l'appartenenza. Se il risultato o la verifica sono
incerti, il resoconto indica Esito da verificare e richiede di aggiornare i
dati prima di riprovare; non ritenta automaticamente il POST. Graph non offre
una transazione che renda atomici controllo dei Ring e aggiunta: due operatori
contemporanei possono ancora concorrere tra ultima lettura e POST.

Il modulo richiede lettura Entra e gruppi. I permessi delegati minimi pertinenti
sono `Device.Read.All` e `GroupMember.Read.All`; per aggiungere dispositivi
`GroupMember.ReadWrite.All`, oltre a lettura dispositivi e diritti del tecnico
sul gruppo. Non occorre `Directory.AccessAsUser.All` per queste assegnazioni.
L'accesso iniziale mostra i consensi mancanti; non li richiede durante l'uso.
Un GET riuscito non prova il diritto di modificare ogni gruppo. Le fonti primarie
sono [aggiunta membri](https://learn.microsoft.com/en-us/graph/api/group-post-members?view=graph-rest-1.0)
e [membri transitivi](https://learn.microsoft.com/en-us/graph/api/group-list-transitivemembers?view=graph-rest-1.0).

I resoconti vanno in `Reports/Ring` nella cartella dati personale e restano
nella scheda Resoconto operazioni. Il CSV della vista include solo le righe
visibili e protegge le celle che potrebbero essere interpretate come formule.
