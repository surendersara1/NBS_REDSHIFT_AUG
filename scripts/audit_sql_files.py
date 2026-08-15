import glob
import os
import re

sql_files = sorted(glob.glob('sql/*.sql'))

findings = {}

for f in sql_files:
    with open(f, 'r', encoding='utf-8', errors='ignore') as fp:
        content = fp.read()
    
    issues = []
    lines = content.split('\n')
    num_lines = len(lines)
    
    # Check for empty/placeholder procedure
    if re.search(r'AS\s+\$\$\s+BEGIN\s+END;\s+\$\$', content, re.IGNORECASE):
        issues.append('Contains empty dummy procedure (AS $$ BEGIN END; $$)')
    if re.search(r'AS\s+\$\$\s+BEGIN\s+RAISE\s+INFO\s+.*conceptual', content, re.IGNORECASE):
        issues.append('Contains purely conceptual placeholder procedure')
        
    f_clean = f.replace('\\', '/')
    m = re.match(r'sql/(\d+)_', f_clean)
    if m:
        num = int(m.group(1))
        if 19 <= num <= 50:
            has_scenario = 'SCENARIO' in content or 'BUSINESS' in content
            has_data_gen = 'DATA GENERATION' in content or 'CREATE TABLE' in content
            has_bad = 'BAD' in content or 'ANTI-PATTERN' in content or 'Anti-Pattern' in content
            has_good = 'GOOD' in content or 'OPTIMIZED' in content or 'MASTER' in content or 'The Redshift Way' in content
            has_explain = any(k in content for k in ['EXPLAIN', 'SVV_', 'SYS_', 'STL_', 'STV_', 'SVL_'])
            has_verification = any(k in content for k in ['CALL ', 'SELECT ', 'EXECUTION'])
            
            missing = []
            if not has_scenario: missing.append('Scenario')
            if not has_data_gen: missing.append('DataGen')
            if not has_bad and num not in [46, 47, 48, 49, 50]: missing.append('Bad/Anti-pattern')
            if not has_good: missing.append('Good/Optimized')
            if not has_explain: missing.append('Explain/Catalog Analysis')
            if missing:
                issues.append('Missing blueprint sections: ' + ', '.join(missing))
        elif 51 <= num <= 59:
            # Check for dummy procedure headers or commented out execution blocks
            if 'AS $$ BEGIN END; $$' in content:
                issues.append('Dummy procedure wrapping examples')
            # Check how many examples are implemented
            ex_count = len(re.findall(r'EXAMPLE\s+\d+', content, re.IGNORECASE))
            if ex_count > 0:
                issues.append(f'Contains {ex_count} examples')
                
    findings[f] = {'lines': num_lines, 'size': os.path.getsize(f), 'issues': issues}

print(f"{'FILE':<48} | {'LINES':<5} | {'SIZE(KB)':<8} | {'ISSUES / NOTES'}")
print("-" * 110)
for f, data in findings.items():
    notes = "; ".join(data['issues']) if data['issues'] else "OK"
    print(f"{f:<48} | {data['lines']:<5} | {data['size']/1024:<8.1f} | {notes}")
