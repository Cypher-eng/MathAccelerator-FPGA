from PIL import Image
import numpy as np

WIDTH = 640
HEIGHT = 480

def parse_vcd(filename):
    pixels = np.zeros((HEIGHT, WIDTH, 3), dtype=np.uint8)
    
    id_map = {}
    signals = {'r': 0, 'g': 0, 'b': 0, 'valid': 0, 'ready': 0, 
               'clk': 0, 'eol': 0, 'sof': 0}
    prev_clk = 0
    x, y = 0, 0

    with open(filename) as f:
        in_header = True
        for line in f:
            line = line.strip()
            
            # Parse header to build id_map
            if in_header:
                if line.startswith('$var'):
                    parts = line.split()
                    # $var wire 1 ! clk $end  →  parts[3]=id, parts[4]=name
                    if len(parts) >= 5:
                        var_id = parts[3]
                        var_name = parts[4]
                        if var_name in signals:
                            id_map[var_id] = var_name
                if '$enddefinitions' in line:
                    in_header = False
                continue
            
            # Parse signal changes
            if line.startswith('#'):
                continue  # timestamp line
            
            if line.startswith('b'):
                # Vector signal e.g. "b00001010 !"
                parts = line.split()
                if len(parts) == 2:
                    value_str = parts[0][1:]  # remove 'b'
                    var_id = parts[1]
                    name = id_map.get(var_id)
                    if name in signals:
                        try:
                            signals[name] = int(value_str, 2)
                        except ValueError:
                            signals[name] = 0
                            
            elif len(line) >= 2 and line[0] in ('0', '1', 'x', 'z'):
                # Scalar signal e.g. "1!" or "0!"
                value = line[0]
                var_id = line[1:]
                name = id_map.get(var_id)
                if name in signals:
                    signals[name] = 0 if value in ('x', 'z') else int(value)
                    
                    # Detect rising clock edge
                    if name == 'clk' and signals['clk'] == 1 and prev_clk == 0:
                        if signals['valid'] and signals['ready']:
                            if 0 <= x < WIDTH and 0 <= y < HEIGHT:
                                pixels[y, x] = [signals['r'], signals['g'], signals['b']]
                            
                            if signals['sof']:
                                x, y = 0, 0
                            elif signals['eol']:
                                x = 0
                                y += 1
                            else:
                                x += 1
                    
                    if name == 'clk':
                        prev_clk = signals['clk']

    return pixels

if __name__ == '__main__':
    print("Parsing VCD file...")
    pixels = parse_vcd('test.vcd')
    print(f"Pixels filled: {np.count_nonzero(pixels.sum(axis=2))} out of {WIDTH*HEIGHT}")
    
    print("Saving image...")
    image = Image.fromarray(pixels, 'RGB')
    image.save('output.png')
    print("Done — check simulation/output.png")