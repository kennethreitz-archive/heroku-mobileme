build:
	curl -O http://rsync.samba.org/ftp/rsync/rsync-3.0.9.tar.gz
	tar xvfz rsync-3.0.9.tar.gz
	cd rsync-3.0.9 && ./configure --prefix=/app/ && make && make install

	./get-wget-warc.sh

init: build
	./seesaw.sh kenneth
