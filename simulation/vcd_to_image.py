from PIL import Image
import numpy as np

WIDTH = 640
HEIGHT = 480

def parse_vcd(filename):
    pixels = np.zeros((HEIGHT, WIDTH, 3), dtype=np.uint8)
    
    # Using internal pixel_generator signals
    ID_R = 'C'
    ID_G = 'G'
    ID_B = 'I'
    ID_CLK = "'"
    ID_READY = 'B'
    ID_X = 'P'
    ID_Y = 'Q'

    signals = {'r': 0, 'g': 0, 'b': 0, 'ready': 0, 'clk': 0, 'x': 0, 'y': 0}
    
    id_map = {
        ID_R: 'r',
        ID_G: 'g',
        ID_B: 'b',
        ID_READY: 'ready',
        ID_CLK: 'clk',
        ID_X: 'x',
        ID_Y: 'y'
    }
    
    prev_clk = 0
    in_header = True
    debug_count = 0

    with open(filename) as f:
        for line in f:
            line = line.strip()
            
            if in_header:
                if '$enddefinitions' in line:
                    in_header = False
                continue
            
            if line.startswith('#'):
                continue
            
            if line.startswith('b'):
                parts = line.split()
                if len(parts) == 2:
                    value_str = parts[0][1:]
                    var_id = parts[1]
                    name = id_map.get(var_id)
                    if name:
                        try:
                            signals[name] = int(value_str, 2)
                        except ValueError:
                            signals[name] = 0
                            
            elif len(line) >= 2 and line[0] in ('0', '1', 'x', 'z'):
                value = line[0]
                var_id = line[1:]
                name = id_map.get(var_id)
                if name:
                    signals[name] = 0 if value in ('x', 'z') else int(value)
                    
                    if name == 'clk' and signals['clk'] == 1 and prev_clk == 0:
                        if signals['ready']:
                            px = signals['x']
                            py = signals['y']
                            
                            if debug_count < 5:
                                print(f"px={px} py={py} r={signals['r']} g={signals['g']} b={signals['b']}")
                                debug_count += 1
                            
                            if 0 <= px < WIDTH and 0 <= py < HEIGHT:
                                pixels[py, px] = [signals['r'], signals['g'], signals['b']]
                    
                    if name == 'clk':
                        prev_clk = signals['clk']

    return pixels

if __name__ == '__main__':
    print("Parsing VCD file...")
    pixels = parse_vcd('test.vcd')
    print(f"Non-zero pixels: {np.count_nonzero(pixels.sum(axis=2))} out of {WIDTH*HEIGHT}")
    
    print("Saving image...")
    image = Image.fromarray(pixels)
    image.save('output.png')
    print("Done — check output.png")