import re,sys
bad=0
for p in sys.argv[1:]:
    L=open(p).read().split('\n'); i=0
    while i<len(L):
        m=re.match(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@',L[i])
        if not m: i+=1; continue
        o=int(m.group(2) or 1); n=int(m.group(4) or 1); i+=1; co=cn=0
        while i<len(L) and (co<o or cn<n):
            c=L[i][:1]
            if c==' ': co+=1; cn+=1
            elif c=='-': co+=1
            elif c=='+': cn+=1
            elif c=='\\': pass
            else: break
            i+=1
        if (co,cn)!=(o,n): bad+=1; print(p,'BAD hunk',m.group(0),'got',co,cn)
print('bad hunks:',bad)
