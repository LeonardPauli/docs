#!/usr/bin/env sh


# subs

cleanup () {
	echo 'ssl.autorenew.clear'
	nw=$'\n'; (crontab -l | sed -E "s/.* # $cron_prefix.*$nw//g") | crontab -
}

ssl_data_makeshift_use_fn () {
	cd "data-makeshift"

	if [ ! -f "$ssl_dhparam_path" ]; then
		touch "$ssl_dhparam_path.makeshift"
		cp ssl/dhparam.pem "$ssl_dhparam_path"
	fi
	if [ ! -f "$ssl_local_ca_key" ]; then
		touch "$ssl_local_ca_key.makeshift"
		cp ca/ca.key "$ssl_local_ca_key"
		cp ca/ca.pem "$ssl_local_ca_crt"
		cp ca/ca.srl "$ssl_local_ca_srl"
	fi
	if [ ! -f "$ssl_local_key" ]; then
		touch "$ssl_local_key.makeshift"
		cp ssl/local.key "$ssl_local_key"
		cp ssl/local.csr "$ssl_local_csr"
		cp ssl/local.crt "$ssl_local_crt"
	fi
	if [ ! -f "$ssl_prod_key" ]; then
		touch "$ssl_prod_key.makeshift"
		cp ssl/prod.key "$ssl_prod_key"
		cp ssl/prod.csr "$ssl_prod_csr"
		cp ssl/prod.crt "$ssl_prod_crt"
	fi

	cd ..
}

ssl_dhparam_create_fn () {
	openssl dhparam -out "$dhparam_path" 4096;
}

ssl_ca_create_fn () {
	openssl genrsa -out "$ca_key" 2048
	openssl req -x509 -new -nodes -sha256 -days 365 \
		-subj "/CN=$ca_displayname" \
		-key "$ca_key" -out "$ca_crt"

	cp data-makeshift/ca/sign-request.sh "$ca_signscript"
	chmod u+x "$ca_signscript"
}


# ssl_crt_create
ssl_crt_key_create () {
	# crt_key
	openssl genrsa -out "$crt_key" 2048
}
ssl_crt_signscript_create () {
	echo "$(cat)" > "$crt_signscript" <<-'EOF'
	#!/usr/bin/env sh
	crt_csr="$1"
	crt_crt="$2"
	EOF
	echo "; cd '$crt'"
	cd PWD
	openssl x509 -req -sha256 -days 30 \
		-CAserial "$ca_crt.srl" -CAcreateserial \
		-CA "$ca_crt" -CAkey "$ca_key" \
		-in "$crt_csr" -out "$crt_crt"
	EOF
	# -extfile $DIR/tmp.ext 
	# todo: logic to check domains / csr content
	chmod u+x "$crt_signscript"
}
ssl_crt_csr_create () {
  # partly based on acme.sh
  # TODO: fix idn support or just use acme.sh's createcsr fn
  # oh, see acme.sh --createCSR

  printf "[ req_distinguished_name ]\n[ req ]\ndistinguished_name = req_distinguished_name\nreq_extensions = v3_req\n[ v3_req ]\n\nkeyUsage = nonRepudiation, digitalSignature, keyEncipherment" > "$crt_csr_conf"

  # domains="$(_idn "$domains")"
  alt="DNS:$(echo "$crt_domains" | sed "s/,,/,/g" | sed "s/,/,DNS:/g")"
  printf -- "\nsubjectAltName=$alt" >> "$crt_csr_conf"

  # [ "$ocsp_use_letsencrypt" ] && printf -- "\nbasicConstraints = CA:FALSE\n1.3.6.1.5.5.7.1.24=DER:30:03:02:01:05" >> "$csrconf"

  # _csr_cn="$(_idn "$domain")"
  # csr_key, not crt_key?
  openssl req -new -sha256 -key "$crt_key" -subj "/CN=$crt_displayname" -config "$crt_csr_conf" -out "$crt_csr"
}
ssl_crt_csr_sign () {
	# crt_csr crt_crt crt_signscript
	crt_signscript "$crt_csr" "$crt_crt"
}
ssl_crt_renewal_setup () {
	name=${1:-anon}
	cron_add "$crt_renew_schedule" "ssl-$name" \
		"( crt_csr='$crt_csr' crt_crt='$crt_crt'; $crt_signscript; )"
	# echo "$(date): set-renew-needed triggered by '$sender'" >> $data/ssl/renew-needed
}


# ssl_acme
ssl_acme () {
	local stagingflag="--staging"; [ "$ssl_acme_staging" = "false" ] && stagingflag=""
	$ssl_acme_home/acme.sh --home "$ssl_acme_home" $stagingflag "$@"
}
ssl_acme_init () { ssl_acme --updateaccount --accountemail "$ssl_acme_notify_email"; }
ssl_acme_csr_sign () {
	# crt_crt?
	ssl_acme --signcsr --csr "$crt_csr" -w "$ssl_acme_webroot";
	
	# --cert-file /path/to/real/cert/file After issue/renew, the cert will be copied to this path.
	# --key-file /path/to/real/key/file After issue/renew, the key will be copied to this path.
	# --ca-file /path/to/real/ca/file After issue/renew, the intermediate cert will be copied to this path.
	# --fullchain-file /path/to/fullchain/file After issue/renew, the fullchain cert will be copied to this path.
	# --reloadcmd "[command]" Command used after issue/renew, usually to reload the server.
	# --csr Specifies the input csr.
}
ssl_acme_crt_renewal_setup () {
	name=${1:-anon}
	crt_signscript="echo whaaat"
	cron_add "$crt_renew_schedule" "ssl-$name" \
		"( crt_csr='$crt_csr' crt_crt='$crt_crt'; $crt_signscript; )"
}


# helpers
cron_add () {
	echo "cron.add: $cron_prefix $2"
	(crontab -l && echo "$1 cd '$(pwd)' && $3 # $cron_prefix $2") | crontab -
}
isnt_created () { ([ ! -f "$1" ] || [ -f "$1.makeshift" ]) && return 0 || return 1; }
keep_alive () { tail -f /dev/null; }