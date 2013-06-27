;;;; tcp.scm - Networking stuff
;
; Copyright (c) 2008-2013, The Chicken Team
; Copyright (c) 2000-2007, Felix L. Winkelmann
; All rights reserved.
;
; Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following
; conditions are met:
;
;   Redistributions of source code must retain the above copyright notice, this list of conditions and the following
;     disclaimer. 
;   Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following
;     disclaimer in the documentation and/or other materials provided with the distribution. 
;   Neither the name of the author nor the names of its contributors may be used to endorse or promote
;     products derived from this software without specific prior written permission. 
;
; THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS
; OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
; AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR
; CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
; CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
; SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
; THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
; OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
; POSSIBILITY OF SUCH DAMAGE.


(declare
  (unit tcp)
  (uses extras scheduler)
  (export tcp-close tcp-listen tcp-connect tcp-accept tcp-accept-ready? ##sys#tcp-port->fileno tcp-listener? tcp-addresses
	  tcp-abandon-port tcp-listener-port tcp-listener-fileno tcp-port-numbers tcp-buffer-size
	  tcp-read-timeout tcp-write-timeout tcp-accept-timeout tcp-connect-timeout)
  (foreign-declare #<<EOF
#include <errno.h>
#ifdef _WIN32
# if (defined(HAVE_WINSOCK2_H) && defined(HAVE_WS2TCPIP_H))
#  include <winsock2.h>
#  include <ws2tcpip.h>
# else
#  include <winsock.h>
# endif
/* Beware: winsock2.h must come BEFORE windows.h */
# define socklen_t       int
static WSADATA wsa;
# define fcntl(a, b, c)  0
# ifndef EWOULDBLOCK
#  define EWOULDBLOCK     0
# endif
# ifndef EINPROGRESS
#  define EINPROGRESS     0
# endif
# ifndef EAGAIN
#  define EAGAIN          0
# endif
# define typecorrect_getsockopt(socket, level, optname, optval, optlen)	\
    getsockopt(socket, level, optname, (char *)optval, optlen)
#else
# include <fcntl.h>
# include <sys/types.h>
# include <sys/socket.h>
# include <sys/time.h>
# include <netinet/in.h>
# include <unistd.h>
# include <netdb.h>
# include <signal.h>
# define closesocket     close
# define INVALID_SOCKET  -1
# define typecorrect_getsockopt getsockopt
#endif

#ifndef SD_RECEIVE
# define SD_RECEIVE      0
# define SD_SEND         1
#endif

#ifdef ECOS
#include <sys/sockio.h>
#endif

#ifndef h_addr
# define h_addr  h_addr_list[ 0 ]
#endif

static char addr_buffer[ 20 ];
EOF
) )

(include "common-declarations.scm")

(register-feature! 'tcp)

(define-foreign-variable errno int "errno")
(define-foreign-variable strerror c-string "strerror(errno)")

(define-foreign-type sockaddr* (pointer "struct sockaddr"))
(define-foreign-type sockaddr_in* (pointer "struct sockaddr_in"))

(define-foreign-variable _af_inet int "AF_INET")
(define-foreign-variable _sock_stream int "SOCK_STREAM")
(define-foreign-variable _sock_dgram int "SOCK_DGRAM")
(define-foreign-variable _sockaddr_size int "sizeof(struct sockaddr)")
(define-foreign-variable _sockaddr_in_size int "sizeof(struct sockaddr_in)")
(define-foreign-variable _sd_receive int "SD_RECEIVE")
(define-foreign-variable _sd_send int "SD_SEND")
(define-foreign-variable _ipproto_tcp int "IPPROTO_TCP")
(define-foreign-variable _invalid_socket int "INVALID_SOCKET")
(define-foreign-variable _ewouldblock int "EWOULDBLOCK")
(define-foreign-variable _eagain int "EAGAIN")
(define-foreign-variable _eintr int "EINTR")
(define-foreign-variable _einprogress int "EINPROGRESS")

(define ##net#socket (foreign-lambda int "socket" int int int))
(define ##net#bind (foreign-lambda int "bind" int scheme-pointer int))
(define ##net#listen (foreign-lambda int "listen" int int))
(define ##net#accept (foreign-lambda int "accept" int c-pointer c-pointer))
(define ##net#close (foreign-lambda int "closesocket" int))
(define ##net#recv (foreign-lambda int "recv" int scheme-pointer int int))
(define ##net#shutdown (foreign-lambda int "shutdown" int int))
(define ##net#connect (foreign-lambda int "connect" int scheme-pointer int))
(define ##net#check-fd-ready (foreign-lambda int "C_check_fd_ready" int))

(define ##net#send
  (foreign-lambda* 
      int ((int s) (scheme-pointer msg) (int offset) (int len) (int flags))
    "C_return(send(s, (char *)msg+offset, len, flags));"))

(define ##net#make-nonblocking
  (foreign-lambda* bool ((int fd))
    "int val = fcntl(fd, F_GETFL, 0);"
    "if(val == -1) C_return(0);"
    "C_return(fcntl(fd, F_SETFL, val | O_NONBLOCK) != -1);") )

(define ##net#getsockname 
  (foreign-lambda* c-string ((int s))
    "struct sockaddr_in sa;"
    "unsigned char *ptr;"
    "int len = sizeof(struct sockaddr_in);"
    "if(getsockname(s, (struct sockaddr *)&sa, (socklen_t *)&len) != 0) C_return(NULL);"
    "ptr = (unsigned char *)&sa.sin_addr;"
    "sprintf(addr_buffer, \"%d.%d.%d.%d\", ptr[ 0 ], ptr[ 1 ], ptr[ 2 ], ptr[ 3 ]);"
    "C_return(addr_buffer);") )

(define ##net#getsockport
  (foreign-lambda* int ((int s))
    "struct sockaddr_in sa;"
    "int len = sizeof(struct sockaddr_in);"
    "if(getsockname(s, (struct sockaddr *)&sa, (socklen_t *)(&len)) != 0) C_return(-1);"
    "else C_return(ntohs(sa.sin_port));") )

(define ##net#getpeerport
 (foreign-lambda* int ((int s))
   "struct sockaddr_in sa;"
   "int len = sizeof(struct sockaddr_in);"
   "if(getpeername(s, (struct sockaddr *)&sa, (socklen_t *)(&len)) != 0) C_return(-1);"
   "else C_return(ntohs(sa.sin_port));") )

(define ##net#getpeername 
  (foreign-lambda* c-string ((int s))
    "struct sockaddr_in sa;"
    "unsigned char *ptr;"
    "unsigned int len = sizeof(struct sockaddr_in);"
    "if(getpeername(s, (struct sockaddr *)&sa, ((unsigned int *)&len)) != 0) C_return(NULL);"
    "ptr = (unsigned char *)&sa.sin_addr;"
    "sprintf(addr_buffer, \"%d.%d.%d.%d\", ptr[ 0 ], ptr[ 1 ], ptr[ 2 ], ptr[ 3 ]);"
    "C_return(addr_buffer);") )

(define ##net#startup
  (foreign-lambda* bool () #<<EOF
#ifdef _WIN32
     C_return(WSAStartup(MAKEWORD(1, 1), &wsa) == 0);
#else
     signal(SIGPIPE, SIG_IGN);
     C_return(1);
#endif
EOF
) )

(unless (##net#startup)
  (##sys#signal-hook #:network-error "cannot initialize Winsock") )

(define ##net#getservbyname 
  (foreign-lambda* int ((c-string serv) (c-string proto))
    "struct servent *se;
     if((se = getservbyname(serv, proto)) == NULL) C_return(0);
     else C_return(ntohs(se->s_port));") )     

(define ##net#gethostaddr
  (foreign-lambda* bool ((scheme-pointer saddr) (c-string host) (unsigned-short port))
    "struct hostent *he = gethostbyname(host);"
    "struct sockaddr_in *addr = (struct sockaddr_in *)saddr;"
    "if(he == NULL) C_return(0);"
    "memset(addr, 0, sizeof(struct sockaddr_in));"
    "addr->sin_family = AF_INET;"
    "addr->sin_port = htons((short)port);"
    "addr->sin_addr = *((struct in_addr *)he->h_addr);"
    "C_return(1);") )

(define-syntax network-error
  (syntax-rules ()
    ((_ loc msg . args)
     (network-error/errno loc (##sys#update-errno) msg . args))))

(define-syntax network-error/errno
  (syntax-rules ()
    ((_ loc errno msg . args)
     (##sys#signal-hook #:network-error loc
			(string-append (string-append msg " - ")
				       (general-strerror errno))
			. args))))

(define ##net#parse-host
  (let ((substring substring))
    (lambda (host proto)
      (let ((len (##sys#size host)))
	(let loop ((i 0))
	  (if (fx>= i len)
	      (values host #f)
	      (let ((c (##core#inline "C_subchar" host i)))
		(if (char=? c #\:)		    
		    (values
		     (substring host (fx+ i 1) len)
		     (let* ((s (substring host 0 i))
			    (p (##net#getservbyname s proto)) )
		       (when (eq? 0 p)
			 (network-error 'tcp-connect "cannot compute port from service" s) )
		       p) )
		    (loop (fx+ i 1)) ) ) ) ) ) ) ) )

(define ##net#fresh-addr
  (foreign-lambda* void ((scheme-pointer saddr) (unsigned-short port))
    "struct sockaddr_in *addr = (struct sockaddr_in *)saddr;"
    "memset(addr, 0, sizeof(struct sockaddr_in));"
    "addr->sin_family = AF_INET;"
    "addr->sin_port = htons(port);"
    "addr->sin_addr.s_addr = htonl(INADDR_ANY);") )

(define (##net#bind-socket port style host)
  (##sys#check-exact port)
  (when (or (fx< port 0) (fx> port 65535))
    (##sys#signal-hook #:domain-error 'tcp-listen "invalid port number" port) )
  (let ((s (##net#socket _af_inet style 0)))
    (when (eq? _invalid_socket s)
      (##sys#update-errno)
      (##sys#error "cannot create socket") )
    ;; PLT makes this an optional arg to tcp-listen. Should we as well?
    (when (eq? -1 ((foreign-lambda* int ((int socket)) 
		     "int yes = 1; 
                      C_return(setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, (const char *)&yes, sizeof(int)));") 
		   s) )
      (network-error 'tcp-listen "error while setting up socket" s) )
    (let ((addr (make-string _sockaddr_in_size)))
      (if host
	  (unless (##net#gethostaddr addr host port)
	    (##sys#signal-hook 
	     #:network-error 'tcp-listen 
	     "getting listener host IP failed" host port) )
	  (##net#fresh-addr addr port) )
      (let ((b (##net#bind s addr _sockaddr_in_size)))
	(when (eq? -1 b)
	  (network-error 'tcp-listen "cannot bind to socket" s port) )
	(values s addr) ) ) ) )

(define-constant default-backlog 100)

(define (tcp-listen port . more)
  (let-optionals more ((w default-backlog) (host #f))
    (let-values (((s addr) (##net#bind-socket port _sock_stream host)))
      (##sys#check-exact w)
      (let ((l (##net#listen s w)))
	(when (eq? -1 l)
	  (network-error 'tcp-listen "cannot listen on socket" s port) )
	(##sys#make-structure 'tcp-listener s) ) ) ) )

(define (tcp-listener? x) 
  (and (##core#inline "C_blockp" x)
       (##sys#structure? x 'tcp-listener) ) )

(define (tcp-close tcpl)
  (##sys#check-structure tcpl 'tcp-listener)
  (let ((s (##sys#slot tcpl 1)))
    (when (fx= -1 (##net#close s))
      (network-error 'tcp-close "cannot close TCP socket" tcpl) ) ) )

(define-constant +input-buffer-size+ 1024)
(define-constant +output-chunk-size+ 8192)

(define tcp-buffer-size (make-parameter #f))
(define tcp-read-timeout)
(define tcp-write-timeout)
(define tcp-connect-timeout)
(define tcp-accept-timeout)

(let ()
  (define ((check loc) x)
    (when x (##sys#check-exact x loc))
    x)
  (define minute (fx* 60 1000))
  (set! tcp-read-timeout (make-parameter minute (check 'tcp-read-timeout)))
  (set! tcp-write-timeout (make-parameter minute (check 'tcp-write-timeout))) 
  (set! tcp-connect-timeout (make-parameter #f (check 'tcp-connect-timeout))) 
  (set! tcp-accept-timeout (make-parameter #f (check 'tcp-accept-timeout))) )

(define ##net#io-ports
  (let ((tbs tcp-buffer-size))
    (lambda (fd)
      (unless (##net#make-nonblocking fd)
	(network-error #f "cannot create TCP ports") )
      (let* ((buf (make-string +input-buffer-size+))
	     (data (vector fd #f #f buf 0))
	     (buflen 0)
	     (bufindex 0)
	     (iclosed #f) 
	     (oclosed #f)
	     (outbufsize (tbs))
	     (outbuf (and outbufsize (fx> outbufsize 0) ""))
	     (tmr (tcp-read-timeout))
             (dlr (and tmr (+ (current-milliseconds) tmr)))
	     (tmw (tcp-write-timeout))
             (dlw (and tmw (+ (current-milliseconds) tmw)))
	     (read-input
	      (lambda ()
		(let loop ()
		  (let ((n (##net#recv fd buf +input-buffer-size+ 0)))
		    (cond ((eq? -1 n)
			   (cond ((or (eq? errno _ewouldblock) 
				      (eq? errno _eagain))
				  (when dlr
				    (##sys#thread-block-for-timeout!
                                     ##sys#current-thread dlr) )
				  (##sys#thread-block-for-i/o! ##sys#current-thread fd #:input)
                                  (##sys#thread-yield!)
				  (when (##sys#slot ##sys#current-thread 13)
				    (##sys#signal-hook
				     #:network-timeout-error
				     "read operation timed out" tmr fd) )
				  (loop) )
				 ((eq? errno _eintr)
				  (##sys#dispatch-interrupt loop))
				 (else
				  (network-error #f "cannot read from socket" fd) ) ) )
			  (else
			   (set! buflen n)
			   (##sys#setislot data 4 n)
			   (set! bufindex 0) ) ) ) ) ) )
	     (in
	      (make-input-port
	       (lambda ()
		 (when (fx>= bufindex buflen)
		   (read-input))
		 (if (fx>= bufindex buflen)
		     #!eof
		     (let ((c (##core#inline "C_subchar" buf bufindex)))
		       (set! bufindex (fx+ bufindex 1))
		       c) ) )
	       (lambda ()
		 (or (fx< bufindex buflen)
		     (let ((f (##net#check-fd-ready fd)))
		       (when (eq? f -1)
			 (network-error #f "cannot check socket for input" fd) )
		       (eq? f 1) ) ) )
	       (lambda ()
		 (unless iclosed
		   (set! iclosed #t)
		   (unless (##sys#slot data 1) (##net#shutdown fd _sd_receive))
		   (when (and oclosed (eq? -1 (##net#close fd)))
		     (network-error #f "cannot close socket input port" fd) ) ) )
	       (lambda ()
		 (when (fx>= bufindex buflen)
		   (read-input))
		 (if (fx< bufindex buflen)
		     (##core#inline "C_subchar" buf bufindex)
		     #!eof))
	       (lambda (p n dest start)	; read-string!
		 (let loop ((n n) (m 0) (start start))
		   (cond ((eq? n 0) m)
			 ((fx< bufindex buflen)
			  (let* ((rest (fx- buflen bufindex))
				 (n2 (if (fx< n rest) n rest)))
			    (##core#inline "C_substring_copy" buf dest bufindex (fx+ bufindex n2) start)
			    (set! bufindex (fx+ bufindex n2))
			    (loop (fx- n n2) (fx+ m n2) (fx+ start n2)) ) )
			 (else
			  (read-input)
			  (if (eq? buflen 0) 
			      m
			      (loop n m start) ) ) ) ) )
	       (lambda (p limit)	; read-line
		 (when (fx>= bufindex buflen)
		   (read-input))
		 (if (fx>= bufindex buflen)
		     #!eof
		     (let ((limit (or limit (fx- (##sys#fudge 21) bufindex))))
		       (receive (next line)
			   (##sys#scan-buffer-line
			    buf
                            (fxmin buflen (fx+ bufindex limit))
                            bufindex
			    (lambda (pos)
			      (let ((nbytes (fx- pos bufindex)))
				(cond ((fx>= nbytes limit)
				       (values #f pos #f))
				      (else (read-input)
					    (set! limit (fx- limit nbytes))
					    (if (fx< bufindex buflen)
						(values buf bufindex
							(fxmin buflen
                                                               (fx+ bufindex limit)))
						(values #f bufindex #f))))) ) )
			 (##sys#setislot p 4 (fx+ (##sys#slot p 4) 1)) ; lineno
			 (set! bufindex next)
			 line) )) )
	       (lambda (p)		; read-buffered
		 (if (fx>= bufindex buflen)
		     ""
		     (let ((str (##sys#substring buf bufpos buflen)))
		       (set! bufpos buflen)
		       str)))
	       ) )
	     (output
	      (lambda (s)
		(let loop ((len (##sys#size s))
			   (offset 0))
		  (let* ((count (fxmin +output-chunk-size+ len))
			 (n (##net#send fd s offset count 0)) )
		    (cond ((eq? -1 n)
			   (cond ((or (eq? errno _ewouldblock)
				      (eq? errno _eagain))
				  (when dlw
				    (##sys#thread-block-for-timeout! 
				     ##sys#current-thread dlw) )
                                  (##sys#thread-block-for-i/o! ##sys#current-thread fd #:output)
                                  (##sys#thread-yield!)
				  (when (##sys#slot ##sys#current-thread 13)
				    (##sys#signal-hook
				     #:network-timeout-error
				     "write operation timed out" tmw fd) )
				  (loop len offset) )
				 ((eq? errno _eintr)
				  (##sys#dispatch-interrupt 
				   (cut loop len offset)))
				 (else
				  (network-error #f "cannot write to socket" fd) ) ) )
			  ((fx< n len)
			   (loop (fx- len n) (fx+ offset n)) ) ) ) ) ) )
	     (out
	      (make-output-port
	       (if outbuf
		   (lambda (s)
		     (set! outbuf (##sys#string-append outbuf s))
		     (when (fx>= (##sys#size outbuf) outbufsize)
		       (output outbuf)
		       (set! outbuf "") ) )
		   (lambda (s) 
		     (when (fx> (##sys#size s) 0)
		       (output s)) ) )
	       (lambda ()
		 (unless oclosed
		   (set! oclosed #t)
		   (when (and outbuf (fx> (##sys#size outbuf) 0))
		     (output outbuf)
		     (set! outbuf "") )
		   (unless (##sys#slot data 2) (##net#shutdown fd _sd_send))
		   (when (and iclosed (eq? -1 (##net#close fd)))
		     (network-error #f "cannot close socket output port" fd) ) ) )
	       (and outbuf
		    (lambda ()
		      (when (fx> (##sys#size outbuf) 0)
			(output outbuf)
			(set! outbuf "") ) ) ) ) ) )
	(##sys#setslot in 3 "(tcp)")
	(##sys#setslot out 3 "(tcp)")
	(##sys#setslot in 7 'socket)
	(##sys#setslot out 7 'socket)
	(##sys#set-port-data! in data)
	(##sys#set-port-data! out data)
	(values in out) ) ) ) )

(define (tcp-accept tcpl)
  (##sys#check-structure tcpl 'tcp-listener)
  (let* ((fd (##sys#slot tcpl 1))
         (tma (tcp-accept-timeout))
         (dla (and tma (+ tma (current-milliseconds)))))
    (let loop ()
      (when dla
        (##sys#thread-block-for-timeout! ##sys#current-thread dla) )
      (##sys#thread-block-for-i/o! ##sys#current-thread fd #:input)
      (##sys#thread-yield!)
      (if (##sys#slot ##sys#current-thread 13)
	  (##sys#signal-hook
	   #:network-timeout-error
	   'tcp-accept
	   "accept operation timed out" tma fd) )
      (let ((fd (##net#accept fd #f #f)))
	(cond ((not (eq? -1 fd)) (##net#io-ports fd))
	      ((eq? errno _eintr)
	       (##sys#dispatch-interrupt loop))
	      (else
	       (network-error 'tcp-accept "could not accept from listener" tcpl)))) ) ) )

(define (tcp-accept-ready? tcpl)
  (##sys#check-structure tcpl 'tcp-listener 'tcp-accept-ready?)
  (let ((f (##net#check-fd-ready (##sys#slot tcpl 1))))
    (when (eq? -1 f)
      (network-error 'tcp-accept-ready? "cannot check socket for input" tcpl) )
    (eq? 1 f) ) )

(define get-socket-error
  (foreign-lambda* int ((int socket))
    "int err, optlen;"
    "optlen = sizeof(err);"
    "if (typecorrect_getsockopt(socket, SOL_SOCKET, SO_ERROR, &err, (socklen_t *)&optlen) == -1)"
    "  C_return(-1);"
    "C_return(err);"))

(define general-strerror (foreign-lambda c-string "strerror" int))

(define (tcp-connect host . more)
  (let* ((port (optional more #f))
         (tmc (tcp-connect-timeout))
         (dlc (and tmc (+ (current-milliseconds) tmc))))
    (##sys#check-string host)
    (unless port
      (set!-values (host port) (##net#parse-host host "tcp"))
      (unless port (##sys#signal-hook #:domain-error 'tcp-connect "no port specified" host)) )
    (##sys#check-exact port)
    (let ((addr (make-string _sockaddr_in_size))
	  (s (##net#socket _af_inet _sock_stream 0)) )
      (when (eq? -1 s)
	(network-error 'tcp-connect "cannot create socket" host port) )
      (unless (##net#gethostaddr addr host port)
	(##sys#signal-hook #:network-error 'tcp-connect "cannot find host address" host) )
      (unless (##net#make-nonblocking s)
	(network-error 'tcp-connect "fcntl() failed") )
      (let loop ()
	(when (eq? -1 (##net#connect s addr _sockaddr_in_size))
	  (cond ((eq? errno _einprogress)
		 (when dlc
		   (##sys#thread-block-for-timeout! ##sys#current-thread dlc))
		 (##sys#thread-block-for-i/o! ##sys#current-thread s #:all)
                 (##sys#thread-yield!))
		((eq? errno _eintr)
		 (##sys#dispatch-interrupt loop))
		(else
		 (##net#close s)
		 (network-error 'tcp-connect "cannot connect to socket" host port)))))
      (let ((err (get-socket-error s)))
	(cond ((fx= err -1)
	       (##net#close s)
	       (network-error 'tcp-connect "getsockopt() failed"))
	      ((fx> err 0)
	       (##net#close s)
	       (network-error/errno 'tcp-connect err "cannot create socket"))))
      (##net#io-ports s) ) ) )

(define (##sys#tcp-port->fileno p)
  (let ((data (##sys#port-data p)))
    (if (vector? data)			; a meagre test, but better than nothing
	(##sys#slot data 0)
	(error '##sys#tcp-port->fileno "argument does not appear to be a TCP port" p))))

(define (tcp-addresses p)
  (##sys#check-open-port p 'tcp-addresses)
  (let ((fd (##sys#tcp-port->fileno p)))
    (values 
     (or (##net#getsockname fd)
	 (network-error 'tcp-addresses "cannot compute local address" p) )
     (or (##net#getpeername fd)
	 (network-error 'tcp-addresses "cannot compute remote address" p) ) ) ) )

(define (tcp-port-numbers p)
  (##sys#check-open-port p 'tcp-port-numbers)
  (let ((fd (##sys#tcp-port->fileno p)))
    (let ((sp (##net#getsockport fd))
	  (pp (##net#getpeerport fd)))
      (when (eq? -1 sp)
	(network-error 'tcp-port-numbers "cannot compute local port" p) )
      (when (eq? -1 pp)
	(network-error 'tcp-port-numbers "cannot compute remote port" p) )
      (values sp pp))))

(define (tcp-listener-port tcpl)
  (##sys#check-structure tcpl 'tcp-listener 'tcp-listener-port)
  (let* ((fd (##sys#slot tcpl 1))
	 (port (##net#getsockport fd)) )
    (when (eq? -1 port)
      (network-error 'tcp-listener-port "cannot obtain listener port" tcpl fd) )
    port) )

(define (tcp-abandon-port p)
  (##sys#check-open-port p 'tcp-abandon-port)
  (##sys#setislot
   (##sys#port-data p)
   (if (##sys#slot p 1) 1 2)
   #t) )

(define (tcp-listener-fileno l)
  (##sys#check-structure l 'tcp-listener 'tcp-listener-fileno)
  (##sys#slot l 1) )
