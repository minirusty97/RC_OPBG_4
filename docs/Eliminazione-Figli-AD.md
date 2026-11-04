# Figli AD non leggibili: dalla versione 1.2.1

La lettura delle informazioni BitLocker e la cancellazione in AD richiedono
permessi distinti. Un tecnico puo vedere il DN di un figlio senza leggerne
classe o ObjectGUID. Il filtro sulla classe puo restituire zero oggetti se
la classe non e leggibile. Non significa che manchino chiavi in AD.

Per i figli con metadati leggibili rimane la cancellazione puntuale per GUID.
Per un figlio con DN visibile ma metadati non leggibili, l anteprima mostra
NON LEGGIBILE e una conferma esplicita della possibile perdita delle chiavi
AD non recuperate, vincolata ai nomi dei computer del piano privato. Il GUID
contenuto nel nome di un eventuale oggetto BitLocker non viene usato come
ObjectGUID AD. Un GUID presente ma malformato resta un errore bloccante.

Prima delle scritture vengono rilette identita del computer, DN, protezione
e figli. Il computer rimane identificato per GUID. La richiesta LDAP per il
figlio usa soltanto il DN confermato sotto quel computer, sullo stesso DC,
con l account Windows corrente, autenticazione Negotiate, firma e cifratura
SASL, timeout limitato e referral disabilitati. Non sono richiesti nuovi
login Graph e non vengono cambiate ACL.

La cancellazione LDAP e ordinaria, senza controlli tree-delete. Se il figlio
contiene oggetti non rimossi o AD nega l eliminazione, la procedura si ferma
per quel computer e le origini successive. Non viene attivata una rimozione
ricorsiva di ripiego. I figli riconosciuti come protetti e il computer protetto
restano bloccati dal controllo applicativo; per il figlio non leggibile sono
le ACL e i controlli del DC a decidere. Dopo una risposta riuscita viene
verificata l assenza prima di proseguire al computer. Non si ritenta una DELETE
con esito incerto. Una modifica concorrente tra verifica e cancellazione
per DN resta possibile: il DN non offre il legame immutabile del GUID.

Le chiavi recuperate dalle fonti disponibili seguono archivio append e
rilettura GLPI. Il resoconto segnala esplicitamente che le eventuali chiavi
AD nascoste non sono garantite nel backup. Errori reali di rete, GLPI o altre
fonti restano bloccanti; questa conferma non li ignora. Le autorizzazioni AD
alla lettura della password non vengono concesse dalla funzione.

Validazione con dati sintetici: figli DN-only, consenso mancante o per altro
computer, normale DELETE senza controlli di sottoalbero, identita sostituita,
nuovi figli, protezioni, rifiuti LDAP, oggetti non foglia, mancata conferma
dell assenza, piani privati, WhatIf e sola lettura. I test non provano i diritti
dell account aziendale. La versione 1.2.1 include la correzione dopo 317
controlli isolati su Windows PowerShell 5.1 e la conferma del tecnico di
procedere alla ricompilazione. Installer e OTA seguono il consueto controllo CI.

Fonti Microsoft:
- https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-adts/8271b44d-a755-4872-a762-1ac57152099d
- https://learn.microsoft.com/en-us/windows/win32/ad/access-control-and-object-deletion
- https://learn.microsoft.com/en-us/dotnet/api/system.directoryservices.protocols.deleterequest
