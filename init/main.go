// Command init is the container entrypoint. It replaces hotio's s6-overlay
// init scripts with the parts that matter for Caddy, then execs Caddy as PID 1:
//
//   - FILE__NAME=/path sets NAME to the contents of /path
//   - UMASK is applied
//   - /config/Caddyfile is installed from /app/Caddyfile if missing
//   - when started as root, /config and /config/Caddyfile are chowned to
//     PUID:PGID and privileges are dropped to that user before Caddy starts
//   - when started as non-root (--user), PUID/PGID are ignored
//   - the Caddyfile is formatted in place (caddy fmt --overwrite)
//   - caddy run --config /config/Caddyfile --adapter caddyfile, with HOME and
//     XDG_{CONFIG,DATA}_HOME pointed at /config so certificates land in
//     /config/caddy exactly like hotio's image
//
// hotio's VPN, Privoxy, Unbound and CUSTOM_BUILD features are not supported;
// enabling one is a fatal error rather than silently running without it.
package main

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"time"
)

func main() {
	if err := run(); err != nil {
		logf("ERR", "%v", err)
		os.Exit(1)
	}
}

func logf(level, format string, args ...any) {
	fmt.Fprintf(os.Stderr, "[%s] [%s] %s\n", time.Now().Format("2006-01-02 15:04:05"), level, fmt.Sprintf(format, args...))
}

func env(key, def string) string {
	if v, ok := os.LookupEnv(key); ok && v != "" {
		return v
	}
	return def
}

func run() error {
	if err := loadFileSecrets(); err != nil {
		return err
	}
	if err := rejectUnsupported(); err != nil {
		return err
	}

	appDir := env("APP_DIR", "/app")
	configDir := env("CONFIG_DIR", "/config")
	caddyfile := configDir + "/Caddyfile"
	caddy := appDir + "/caddy"

	umask, err := strconv.ParseUint(env("UMASK", "002"), 8, 32)
	if err != nil {
		return fmt.Errorf("invalid UMASK %q: %w", os.Getenv("UMASK"), err)
	}
	syscall.Umask(int(umask))

	asRoot := os.Geteuid() == 0
	uid, gid := os.Geteuid(), os.Getegid()
	if asRoot {
		if uid, err = envID("PUID"); err != nil {
			return err
		}
		if gid, err = envID("PGID"); err != nil {
			return err
		}
		if uid == 0 {
			logf("WRN", "PUID=0, Caddy will run as root.")
		}
	} else if os.Getenv("PUID") != strconv.Itoa(uid) || os.Getenv("PGID") != strconv.Itoa(gid) {
		logf("INF", "Started as %d:%d, ignoring PUID/PGID.", uid, gid)
	}
	logf("INF", "PUID=%d PGID=%d UMASK=%s TZ=%s", uid, gid, env("UMASK", "002"), os.Getenv("TZ"))

	if err := installDefault(appDir+"/Caddyfile", caddyfile); err != nil {
		return err
	}
	if asRoot {
		for _, p := range []string{configDir, caddyfile} {
			if err := chownIfNeeded(p, uid, gid); err != nil {
				return err
			}
		}
		if err := dropPrivileges(uid, gid); err != nil {
			return err
		}
	}

	// Same layout as hotio's service-caddy/run.
	os.Setenv("HOME", configDir)
	os.Setenv("XDG_CONFIG_HOME", configDir)
	os.Setenv("XDG_DATA_HOME", configDir)

	fmtCmd := exec.Command(caddy, "fmt", caddyfile, "--overwrite")
	fmtCmd.Stdout, fmtCmd.Stderr = os.Stderr, os.Stderr
	if err := fmtCmd.Run(); err != nil {
		logf("WRN", "caddy fmt failed: %v", err)
	}

	// Arguments (the image CMD) replace the default `caddy run` invocation.
	argv := []string{caddy, "run", "--config", caddyfile, "--adapter", "caddyfile"}
	if len(os.Args) > 1 {
		argv = append([]string{caddy}, os.Args[1:]...)
	}
	logf("INF", "Starting %s", strings.Join(argv, " "))
	return syscall.Exec(caddy, argv, os.Environ())
}

// loadFileSecrets implements hotio's FILE__ convention: FILE__FOO=/run/secrets/foo
// sets FOO to the file's contents (trailing newlines stripped, as $(cat) does).
func loadFileSecrets() error {
	for _, kv := range os.Environ() {
		key, path, _ := strings.Cut(kv, "=")
		name, ok := strings.CutPrefix(key, "FILE__")
		if !ok || name == "" {
			continue
		}
		b, err := os.ReadFile(path)
		if err != nil {
			return fmt.Errorf("[%s] cannot read secret file [%s]: %w", name, path, err)
		}
		b = bytes.TrimRight(b, "\n")
		if len(b) == 0 {
			return fmt.Errorf("[%s] no secret found in [%s]", name, path)
		}
		os.Setenv(name, string(b))
		os.Unsetenv(key)
		logf("INF", "[%s] Set with secret from [%s].", name, path)
	}
	return nil
}

func rejectUnsupported() error {
	for _, k := range []string{"VPN_ENABLED", "PRIVOXY_ENABLED", "UNBOUND_ENABLED"} {
		if os.Getenv(k) == "true" {
			return fmt.Errorf("%s=true is not supported by this image; use ghcr.io/hotio/caddy for that", k)
		}
	}
	if os.Getenv("CUSTOM_BUILD") != "" {
		return errors.New("CUSTOM_BUILD is not supported by this image; the bundled binary is always used")
	}
	return nil
}

func envID(key string) (int, error) {
	v := env(key, "1000")
	id, err := strconv.ParseUint(v, 10, 31)
	if err != nil {
		return 0, fmt.Errorf("invalid %s %q", key, v)
	}
	return int(id), nil
}

func installDefault(src, dst string) error {
	if _, err := os.Stat(dst); err == nil {
		return nil
	} else if !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	logf("INF", "Installing default [%s] file.", dst)
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o666)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

func chownIfNeeded(path string, uid, gid int) error {
	fi, err := os.Lstat(path)
	if err != nil {
		return err
	}
	st := fi.Sys().(*syscall.Stat_t)
	if int(st.Uid) == uid && int(st.Gid) == gid {
		return nil
	}
	logf("INF", "Taking ownership of [%s].", path)
	return os.Lchown(path, uid, gid)
}

// dropPrivileges switches every thread to uid:gid, with gid as the only
// group. Go applies setuid/setgid process-wide on Linux.
func dropPrivileges(uid, gid int) error {
	if uid == 0 {
		return nil
	}
	if err := syscall.Setgroups([]int{gid}); err != nil {
		return fmt.Errorf("setgroups: %w", err)
	}
	if err := syscall.Setgid(gid); err != nil {
		return fmt.Errorf("setgid: %w", err)
	}
	if err := syscall.Setuid(uid); err != nil {
		return fmt.Errorf("setuid: %w", err)
	}
	return nil
}
