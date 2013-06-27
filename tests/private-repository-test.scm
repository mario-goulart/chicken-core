;;;; private-repository-test.scm


(use files posix)

(define read-symbolic-link*
  (cond-expand
   ((and windows (not cygwin)) (lambda (x) x))
   (else read-symbolic-link)))

(define repo (normalize-pathname (read-symbolic-link* (repository-path) #t)))
(define dir (normalize-pathname (read-symbolic-link* (car (command-line-arguments)) #t)))

(print (list dir repo))

(assert (string=? repo dir))

