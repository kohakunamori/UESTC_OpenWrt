package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestNormalizeInitialURL(t *testing.T) {
	tests := map[string]string{
		"172.25.249.64":              "http://172.25.249.64",
		"110.184.24.61/portal/main":  "http://110.184.24.61/portal/main",
		"http://example.com/probe":   "http://example.com/probe",
		"https://example.com/probe":  "https://example.com/probe",
		"/connectivitycheck.example": "http://connectivitycheck.example",
	}

	for input, want := range tests {
		if got := normalizeInitialURL(input); got != want {
			t.Fatalf("normalizeInitialURL(%q) = %q, want %q", input, got, want)
		}
	}
}

func TestDefaultInitialURLIsCaptiveProbe(t *testing.T) {
	if defaultInitialURL != "http://connectivitycheck.gstatic.com/generate_204" {
		t.Fatalf("defaultInitialURL = %q", defaultInitialURL)
	}
	if captiveProbeURLs[0] != defaultInitialURL {
		t.Fatalf("first captive probe = %q, want defaultInitialURL", captiveProbeURLs[0])
	}
}

func TestResolveRedirectURLHandlesRelativeLocation(t *testing.T) {
	got, err := resolveRedirectURL("http://110.184.24.61/self/index", "/login")
	if err != nil {
		t.Fatal(err)
	}
	if want := "http://110.184.24.61/login"; got != want {
		t.Fatalf("resolved redirect = %q, want %q", got, want)
	}
}

func TestLoginInitFollowsRelativeRedirectsToPortalMain(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/start":
			http.Redirect(w, r, "/eportal/index.jsp?userip=100.67.96.131&nasip=171.88.130.251&wlanparameter=aa-bb-cc", http.StatusFound)
		case "/eportal/index.jsp":
			http.Redirect(w, r, "/portal/portal-main?sessionId=sid123&userIp=100.67.96.131&nasIp=171.88.130.251&customPageId=page456", http.StatusFound)
		case "/portal/portal-main":
			w.WriteHeader(http.StatusOK)
		default:
			t.Fatalf("unexpected request path %q", r.URL.Path)
		}
	}))
	defer server.Close()

	client := &loginClient{initHost: server.URL + "/start"}
	client.loginInit()

	wantHost := strings.TrimPrefix(server.URL, "http://")
	if client.loginHost != wantHost {
		t.Fatalf("loginHost = %q, want %q", client.loginHost, wantHost)
	}
	if client.portalMain == nil {
		t.Fatal("portalMain was not captured")
	}
	if got := client.portalMain.Query().Get("sessionId"); got != "sid123" {
		t.Fatalf("sessionId = %q, want sid123", got)
	}
	if client.nodeMac != "aa-bb-cc" {
		t.Fatalf("nodeMac = %q, want aa-bb-cc", client.nodeMac)
	}
}

func TestFollowPortalRedirectsDetectsLoop(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/loop", http.StatusFound)
	}))
	defer server.Close()

	client := &loginClient{}
	_, _, err := client.followPortalRedirects(server.URL + "/loop")
	if err == nil {
		t.Fatal("expected redirect loop error")
	}
	if !strings.Contains(err.Error(), "redirect loop") {
		t.Fatalf("error = %q, want redirect loop", err)
	}
}
