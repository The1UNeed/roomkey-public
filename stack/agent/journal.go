package main

import (
	"encoding/json"
	"log"
	"os"
	"path/filepath"
)

// The task journal: every result is written to disk before the panel hears
// of it, and kept for the last journalKeep tasks. A restart between running a
// task and reporting it loses nothing, and a task the panel hands out again
// (its result never arrived) is answered with the result it had, not run a
// second time: a node created once would otherwise come back as a conflict
// with itself.
const journalKeep = 200

type journalFile struct {
	Pending []result `json:"pending"`
	Recent  []result `json:"recent"` // oldest first
	// what follows the panel taking a pending result: a leave uninstalls
	// psm-agent, an agent.update upgrades it (a restart in between still does it)
	Leaving   bool `json:"leaving,omitempty"`
	Upgrading bool `json:"upgrading,omitempty"`
}

func (a *agent) journalPath() string {
	if a.cfgPath == "" {
		return "" // tests
	}
	return filepath.Join(filepath.Dir(a.cfgPath), "agent-tasks.json")
}

// ran records a task's result: pending for the panel, and remembered.
func (a *agent) ran(r result) {
	a.pending = append(a.pending, r)
	if r.UID != "" {
		a.recent = append(a.recent, r)
		if len(a.recent) > journalKeep {
			a.recent = append([]result(nil), a.recent[len(a.recent)-journalKeep:]...)
		}
	}
	a.saveJournal()
}

// replayed is the result a task already had, if it ran here before: the same
// task, by its uid (a panel restored from a backup numbers its tasks from 1
// again, so the id alone could name a different task). A task without a uid
// is never answered from the journal.
func (a *agent) replayed(t task) (result, bool) {
	if t.UID == "" {
		return result{}, false
	}
	for i := len(a.recent) - 1; i >= 0; i-- {
		if a.recent[i].UID == t.UID && a.recent[i].TaskID == t.ID {
			return a.recent[i], true
		}
	}
	return result{}, false
}

func (a *agent) saveJournal() {
	p := a.journalPath()
	if p == "" {
		return
	}
	raw, _ := json.Marshal(journalFile{Pending: a.pending, Recent: a.recent, Leaving: a.leaving, Upgrading: a.upgrading})
	err := os.WriteFile(p+".tmp", raw, 0o600)
	if err == nil {
		err = os.Rename(p+".tmp", p)
	}
	if err != nil {
		log.Printf("task journal: %v", err)
	}
}

func (a *agent) loadJournal() {
	p := a.journalPath()
	if p == "" {
		return
	}
	raw, err := os.ReadFile(p)
	if err != nil {
		return
	}
	var j journalFile
	if json.Unmarshal(raw, &j) != nil {
		log.Printf("task journal %s: unreadable, starting afresh", p)
		return
	}
	a.pending, a.recent, a.leaving, a.upgrading = j.Pending, j.Recent, j.Leaving, j.Upgrading
	if len(a.recent) > journalKeep {
		a.recent = a.recent[len(a.recent)-journalKeep:]
	}
}
